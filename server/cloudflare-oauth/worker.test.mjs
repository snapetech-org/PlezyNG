import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = await readFile(new URL('./worker.mjs', import.meta.url), 'utf8');
const module = await import('data:text/javascript;base64,' + Buffer.from(source + '\nexport { DAILY_SESSIONS, verify, TTL_MS };').toString('base64'));
const { default: worker, OAuthSession, OAuthAdmission, DAILY_SESSIONS, verify, TTL_MS } = module;

const origin = 'https://pleazyng-api.snape.tech';
class MemoryStorage {
  values = new Map(); writes = 0; alarm = null;
  async get(k) { return structuredClone(this.values.get(k)); }
  async put(k, v) { this.writes++; this.values.set(k, structuredClone(v)); }
  async deleteAll() { this.writes++; this.values.clear(); }
  async setAlarm(v) { this.writes++; this.alarm = v; }
  async deleteAlarm() { this.writes++; this.alarm = null; }
}
function context(storage = new MemoryStorage()) {
  return { storage, blockConcurrencyWhile(fn) { this.ready = fn(); } };
}
function fixture() {
  const env = { START_LIMIT: { async limit() { return { success: true }; } }, PUBLIC_ORIGIN: origin, SESSION_SIGNING_KEY: 'test-signing-material-with-at-least-32-bytes', MAL_CLIENT_ID: 'owned-mal', ANILIST_CLIENT_ID: 'owned-anilist', ANILIST_CLIENT_SECRET: 'test-anilist-secret' };
  const sessions = new Map(); const admissions = new Map();
  function namespace(Class, objects) {
    return { calls: 0, idFromName: value => value, get(id) {
      if (!objects.has(id)) {
        const ctx = context(); const object = new Class(ctx, env); objects.set(id, { ctx, object });
      }
      return { fetch: async request => { this.calls++; assert.equal(request.redirect, 'manual', 'Durable Object redirects must reach the browser'); const { ctx, object } = objects.get(id); await ctx.ready; return object.fetch(request); } };
    }};
  }
  env.SESSIONS = namespace(OAuthSession, sessions); env.ADMISSION = namespace(OAuthAdmission, admissions);
  async function call(path, { method = 'GET', body, ip = '192.0.2.1', headers = {} } = {}) {
    return worker.fetch(new Request(`${origin}${path}`, { method, headers: { 'CF-Connecting-IP': ip, 'Content-Type': 'application/json', ...headers }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }), env);
  }
  async function start(service = 'mal') {
    const response = await call('/auth/start', { method: 'POST', body: { service } }); assert.equal(response.status, 200);
    const value = await response.json(); const state = new URL(value.url).searchParams.get('state');
    return { ...value, state, entry: sessions.values().next().value };
  }
  return { env, sessions, admissions, call, start };
}

test('MAL start, PKCE exchange, long poll, single-use result; no poll writes', async t => {
  const f = fixture(); const s = await f.start();
  const authorize = await f.call(`/auth/mal?state=${s.state}`);
  assert.equal(authorize.status, 302);
  const upstream = new URL(authorize.headers.get('Location'));
  assert.equal(upstream.hostname, 'myanimelist.net');
  assert.equal(upstream.searchParams.get('code_challenge_method'), 'plain');
  assert.equal(upstream.searchParams.get('state'), s.state);
  let exchanges = 0;
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    exchanges++; assert.equal(url, 'https://myanimelist.net/v1/oauth2/token');
    assert.equal(options.body.get('code_verifier'), upstream.searchParams.get('code_challenge'));
    assert.equal(options.body.get('redirect_uri'), `${origin}/auth/mal/callback`);
    assert.equal(options.redirect, 'error');
    return Response.json({ access_token: 'access-test', refresh_token: 'refresh-test', expires_in: 3600 });
  });
  const writes = s.entry.ctx.storage.writes;
  const pending = f.call(`/auth/result?session=${s.session}`);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(s.entry.ctx.storage.writes, writes, 'pending poll is read-only');
  assert.equal((await f.call(`/auth/result?session=${s.session}`)).status, 429);
  assert.equal((await f.call(`/auth/mal/callback?state=${s.state}&code=owned-code`)).status, 200);
  assert.deepEqual(await (await pending).json(), { accessToken: 'access-test', refreshToken: 'refresh-test', expiresIn: 3600 });
  assert.equal(exchanges, 1);
  assert.equal((await f.call(`/auth/result?session=${s.session}`)).status, 410);
  assert.equal((await f.call(`/auth/mal/callback?state=${s.state}&code=replay`)).status, 410);
  assert.equal(s.entry.ctx.storage.values.size, 0);
  assert.equal(s.entry.ctx.storage.alarm, null);
});

test('pending poll timeout writes nothing', async t => {
  const f = fixture(); const s = await f.start();
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const writes = s.entry.ctx.storage.writes;
  const poll = f.call(`/auth/result?session=${s.session}`);
  // Signature verification is asynchronous and precedes the object fetch.
  while (!s.entry.object.waiter) await new Promise(resolve => setImmediate(resolve));
  t.mock.timers.tick(50_001);
  assert.equal((await poll).status, 204);
  assert.equal(s.entry.ctx.storage.writes, writes);
});

test('forged/expired capabilities never invoke storage; browser capability cannot poll', async () => {
  const f = fixture(); const s = await f.start(); const before = f.env.SESSIONS.calls;
  assert.equal((await f.call(`/auth/result?session=${s.state}`)).status, 410);
  const forged = s.session.slice(0, -1) + (s.session.endsWith('a') ? 'b' : 'a');
  assert.equal((await f.call(`/auth/result?session=${forged}`)).status, 410);
  assert.equal(await verify(f.env, 'device', 'e1_bad'), null);
  assert.equal(f.env.SESSIONS.calls, before);
  assert.equal((await f.call(`/auth/anilist?state=${s.state}`)).status, 404);
});

test('duplicate callbacks claim before upstream exchange, including after cold reload', async t => {
  const f = fixture(); const s = await f.start('anilist'); let release; let exchanges = 0;
  t.mock.method(globalThis, 'fetch', async (_url, options) => {
    exchanges++; assert.equal(options.body.get('client_secret'), 'test-anilist-secret');
    await new Promise(resolve => { release = resolve; }); return Response.json({ access_token: 'once' });
  });
  const callback = f.call(`/auth/anilist/callback?state=${s.state}&code=code`);
  while (!release) await new Promise(resolve => setImmediate(resolve));
  assert.equal((await f.call(`/auth/anilist/callback?state=${s.state}&code=code`)).status, 404);
  release(); assert.equal((await callback).status, 200); assert.equal(exchanges, 1);
  const ctx = context(s.entry.ctx.storage); const reloaded = new OAuthSession(ctx, f.env); await ctx.ready;
  assert.equal((await reloaded.fetch(new Request('https://session.internal/callback', { method: 'POST', body: JSON.stringify({ service: 'anilist', code: 'replay' }) }))).status, 404);
  assert.equal((await f.call(`/auth/result?session=${s.session}`)).status, 200);
});

test('provider denial and failed exchange return sanitized device errors', async t => {
  const f = fixture(); const s = await f.start();
  const denial = await f.call(`/auth/mal/callback?state=${s.state}&error=access_denied&error_description=PRIVATE`);
  assert.equal(denial.status, 200); assert.ok(!(await denial.text()).includes('PRIVATE'));
  assert.deepEqual(await (await f.call(`/auth/result?session=${s.session}`)).json(), { error: 'access_denied' });
  const s2 = await f.start();
  t.mock.method(globalThis, 'fetch', async () => new Response('PRIVATE UPSTREAM TOKEN', { status: 500 }));
  assert.equal((await f.call(`/auth/mal/callback?state=${s2.state}&code=x`)).status, 502);
  assert.deepEqual(await (await f.call(`/auth/result?session=${s2.session}`)).json(), { error: 'exchange_failed' });
});

test('global admission cap persists; rejected attempts do not write; per-IP burst bounded', async () => {
  const ctx = context(); const admission = new OAuthAdmission(ctx); await ctx.ready;
  const req = client => new Request('https://quota.internal/admit', { method: 'POST', body: JSON.stringify({ client }) });
  for (let i = 0; i < 3; i++) assert.equal((await admission.fetch(req('same'))).status, 204);
  let writes = ctx.storage.writes;
  assert.equal((await admission.fetch(req('same'))).status, 429); assert.equal(ctx.storage.writes, writes);
  for (let i = 3; i < DAILY_SESSIONS; i++) assert.equal((await admission.fetch(req(`client-${i}`))).status, 204);
  const reloadedCtx = context(ctx.storage); const reloaded = new OAuthAdmission(reloadedCtx); await reloadedCtx.ready;
  writes = ctx.storage.writes;
  assert.equal((await reloaded.fetch(req('another'))).status, 429); assert.equal(ctx.storage.writes, writes);
});

test('Trakt browser PKCE, Steam, legacy sessions, and unknown paths pass through unchanged', async t => {
  const f = fixture(); const requests = [];
  t.mock.method(globalThis, 'fetch', async request => { requests.push(request); return new Response('local', { status: 202 }); });
  for (const service of ['trakt', 'steam', 'steam-cloud']) {
    assert.equal((await f.call('/auth/start', { method: 'POST', body: { service } })).status, 202);
    assert.equal((await requests.at(-1).json()).service, service);
  }
  for (const path of ['/auth/trakt/callback?state=local', '/auth/steam/library', '/auth/result?session=legacy', '/auth/result?session=e1_' + 'a'.repeat(21), '/auth/mal/callback?state=legacy&code=x']) {
    assert.equal((await f.call(path)).status, 202); assert.equal(new URL(requests.at(-1).url).pathname, new URL(origin + path).pathname);
  }
  assert.equal(f.sessions.size, 0); assert.equal(f.admissions.size, 0);
});

test('unconfigured providers and oversized bodies cannot create state; expiry cleans secrets', async () => {
  const f = fixture(); f.env.ANILIST_CLIENT_SECRET = '';
  assert.equal((await f.call('/auth/start', { method: 'POST', body: { service: 'anilist' } })).status, 503);
  assert.equal((await f.call('/auth/start', { method: 'POST', body: { service: 'mal', padding: 'a'.repeat(1024) } })).status, 413);
  assert.equal(f.admissions.size, 0);
  const s = await f.start(); await s.entry.object.alarm();
  assert.equal(s.entry.ctx.storage.values.size, 0);
  assert.equal((await f.call(`/auth/result?session=${s.session}`)).status, 410);
  assert.equal(s.expiresIn, TTL_MS / 1000);
});


test('edge start limiter rejects attempts before any object call', async () => {
  const f = fixture(); f.env.START_LIMIT.limit = async () => ({ success: false });
  assert.equal((await f.call('/auth/start', { method: 'POST', body: { service: 'mal' } })).status, 429);
  assert.equal(f.admissions.size, 0); assert.equal(f.sessions.size, 0);
});

test('declared and streamed oversized bodies reject promptly without state allocation', async () => {
  for (const declared of [true, false]) {
    const f = fixture();
    const body = declared ? 'x'.repeat(1024) : new ReadableStream({
      start(controller) { controller.enqueue(new TextEncoder().encode('x'.repeat(1024))); controller.close(); },
    });
    const request = new Request(`${origin}/auth/start`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', ...(declared ? { 'Content-Length': '1024' } : {}) },
      body, ...(declared ? {} : { duplex: 'half' }),
    });
    let timer;
    try {
      const response = await Promise.race([worker.fetch(request, f.env), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('body rejection hung')), 500); })]);
      assert.equal(response.status, 413);
      assert.equal(f.sessions.size, 0); assert.equal(f.admissions.size, 0);
    } finally { clearTimeout(timer); }
  }
});

test('browser-simple and cross-site starts cannot spend login quota', async () => {
  const f = fixture();
  for (const headers of [
    { 'Content-Type': 'text/plain' }, { Origin: 'https://untrusted.example' },
    { Origin: 'null' }, { 'Sec-Fetch-Site': 'cross-site' },
  ]) {
    const response = await f.call('/auth/start', { method: 'POST', body: { service: 'mal' }, headers });
    assert.equal(response.status, headers['Content-Type'] ? 415 : 403);
  }
  assert.equal(f.sessions.size, 0); assert.equal(f.admissions.size, 0);
  assert.equal((await f.call('/auth/start', { method: 'POST', body: { service: 'mal' }, headers: { Origin: origin } })).status, 200);
});

test('one client cannot consume the global daily admission budget by waiting out burst limits', async t => {
  let now = Date.now(); t.mock.method(Date, 'now', () => now);
  const ctx = context(); const admission = new OAuthAdmission(ctx); await ctx.ready;
  const req = client => new Request('https://quota.internal/admit', { method: 'POST', body: JSON.stringify({ client }) });
  for (let i = 0; i < 10; i++) {
    assert.equal((await admission.fetch(req('same-client'))).status, 204); now += 60_001;
  }
  const writes = ctx.storage.writes;
  const reloadedCtx = context(ctx.storage); const reloaded = new OAuthAdmission(reloadedCtx); await reloadedCtx.ready;
  assert.equal((await reloaded.fetch(req('same-client'))).status, 429);
  assert.equal(ctx.storage.writes, writes);
  assert.equal((await reloaded.fetch(req('other-client'))).status, 204);
});

test('edge responses carry no-store, referrer, MIME and frame protections', async () => {
  const f = fixture(); const s = await f.start();
  for (const response of [await f.call('/auth/edge-health'), await f.call('/auth/mal?state=' + s.state), await f.call('/auth/result?session=e1_invalid')]) {
    assert.equal(response.headers.get('X-Content-Type-Options'), 'nosniff');
    assert.equal(response.headers.get('Referrer-Policy'), 'no-referrer');
    assert.equal(response.headers.get('X-Frame-Options'), 'DENY');
    assert.match(response.headers.get('Strict-Transport-Security'), /max-age=31536000/);
    assert.match(response.headers.get('Cache-Control'), /no-store/);
  }
});
