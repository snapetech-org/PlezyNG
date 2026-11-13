import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = await readFile(new URL('./worker.mjs', import.meta.url), 'utf8');
const module = await import('data:text/javascript;base64,' + Buffer.from(source + '\nexport { ADMISSION_BURST, verify, TTL_MS };').toString('base64'));
const { default: worker, OAuthSession, OAuthAdmission, ADMISSION_BURST, verify, TTL_MS } = module;

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
  const env = { START_LIMIT: { async limit() { return { success: true }; } }, PUBLIC_ORIGIN: origin, SESSION_SIGNING_KEY: 'test-signing-material-with-at-least-32-bytes', MAL_CLIENT_ID: 'owned-mal' };
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
    const response = await call('/auth/pkce/start', { method: 'POST', body: { service } }); assert.equal(response.status, 200);
    const value = await response.json(); const state = new URL(value.url).searchParams.get('state');
    return { ...value, state, entry: sessions.values().next().value };
  }
  return { env, sessions, admissions, call, poll: session => call('/auth/result', { headers: { Authorization: `Bearer ${session}` } }), start };
}

test('MAL code-only handoff, long poll, single-use result; no poll writes', async t => {
  const f = fixture(); const s = await f.start();
  const authorize = new URL(s.url);
  assert.equal(authorize.hostname, 'myanimelist.net');
  assert.equal(authorize.pathname, '/v1/oauth2/authorize');
  assert.equal(authorize.searchParams.get('response_type'), 'code');
  assert.equal(authorize.searchParams.get('redirect_uri'), `${origin}/auth/mal/callback`);
  assert.equal(authorize.searchParams.get('state'), s.state);
  assert.equal(authorize.searchParams.has('code_challenge'), false);
  assert.equal(authorize.searchParams.has('code_challenge_method'), false);
  const writes = s.entry.ctx.storage.writes;
  const pending = f.poll(s.session);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(s.entry.ctx.storage.writes, writes, 'pending poll is read-only');
  assert.equal((await f.poll(s.session)).status, 429);
  assert.equal((await f.call(`/auth/mal/callback?state=${s.state}&code=owned-code`)).status, 200);
  assert.deepEqual(await (await pending).json(), { authorizationCode: 'owned-code' });
  assert.equal((await f.poll(s.session)).status, 410);
  assert.equal((await f.call(`/auth/mal/callback?state=${s.state}&code=replay`)).status, 410);
  assert.equal(s.entry.ctx.storage.values.size, 0);
  assert.equal(s.entry.ctx.storage.alarm, null);
});

test('pending poll timeout writes nothing', async t => {
  const f = fixture(); const s = await f.start();
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const writes = s.entry.ctx.storage.writes;
  const poll = f.poll(s.session);
  // Signature verification is asynchronous and precedes the object fetch.
  while (!s.entry.object.waiter) await new Promise(resolve => setImmediate(resolve));
  t.mock.timers.tick(50_001);
  assert.equal((await poll).status, 204);
  assert.equal(s.entry.ctx.storage.writes, writes);
});

test('forged/expired capabilities never invoke storage; browser capability cannot poll', async () => {
  const f = fixture(); const s = await f.start(); const before = f.env.SESSIONS.calls;
  assert.equal((await f.poll(s.state)).status, 410);
  const forged = s.session.slice(0, -1) + (s.session.endsWith('a') ? 'b' : 'a');
  assert.equal((await f.poll(forged)).status, 410);
  assert.equal(await verify(f.env, 'device', 'e1_bad'), null);
  assert.equal(f.env.SESSIONS.calls, before);
  assert.equal((await f.call(`/auth/anilist?state=${s.state}`)).status, 404);
});

test('duplicate callbacks claim before storing a code, including after cold reload', async () => {
  const f = fixture(); const s = await f.start();
  const callback = f.call(`/auth/mal/callback?state=${s.state}&code=code`);
  assert.equal((await callback).status, 200);
  assert.equal((await f.call(`/auth/mal/callback?state=${s.state}&code=code`)).status, 404);
  const ctx = context(s.entry.ctx.storage); const reloaded = new OAuthSession(ctx, f.env); await ctx.ready;
  assert.equal((await reloaded.fetch(new Request('https://session.internal/callback', { method: 'POST', body: JSON.stringify({ service: 'mal', code: 'replay' }) }))).status, 404);
  assert.deepEqual(await (await f.poll(s.session)).json(), { authorizationCode: 'code' });
});

test('provider denial returns a sanitized device error; successful callbacks return only a code', async () => {
  const f = fixture(); const s = await f.start();
  const denial = await f.call(`/auth/mal/callback?state=${s.state}&error=access_denied&error_description=PRIVATE`);
  assert.equal(denial.status, 200); assert.ok(!(await denial.text()).includes('PRIVATE'));
  assert.deepEqual(await (await f.poll(s.session)).json(), { error: 'access_denied' });
  const s2 = await f.start();
  assert.equal((await f.call(`/auth/mal/callback?state=${s2.state}&code=single-use`)).status, 200);
  assert.deepEqual(await (await f.poll(s2.session)).json(), { authorizationCode: 'single-use' });
});

test('rolling admission persists, rejections do not write, and capacity replenishes', async t => {
  let now = Date.now(); t.mock.method(Date, 'now', () => now);
  const ctx = context(); const admission = new OAuthAdmission(ctx); await ctx.ready;
  const req = client => new Request('https://quota.internal/admit', { method: 'POST', body: JSON.stringify({ client }) });
  for (let i = 0; i < 3; i++) assert.equal((await admission.fetch(req('same'))).status, 204);
  let writes = ctx.storage.writes;
  assert.equal((await admission.fetch(req('same'))).status, 429); assert.equal(ctx.storage.writes, writes);
  for (let i = 3; i < ADMISSION_BURST; i++) assert.equal((await admission.fetch(req(`client-${i}`))).status, 204);
  const reloadedCtx = context(ctx.storage); const reloaded = new OAuthAdmission(reloadedCtx); await reloadedCtx.ready;
  writes = ctx.storage.writes;
  const rejected = await reloaded.fetch(req('another'));
  assert.equal(rejected.status, 429); assert.equal(rejected.headers.get('Retry-After'), '900');
  assert.equal(ctx.storage.writes, writes);
  now += 900_000;
  assert.equal((await reloaded.fetch(req('new-legitimate-client'))).status, 204);
  assert.equal((await reloaded.fetch(req('another-new-client'))).status, 429);
});

test('the first-party hostname never forwards relay requests to the home origin', async t => {
  const f = fixture(); let forwards = 0;
  t.mock.method(globalThis, 'fetch', async () => { forwards++; return new Response('origin', { status: 202 }); });
  for (const service of ['anilist', 'trakt', 'steam', 'steam-cloud']) {
    assert.equal((await f.call('/auth/start', { method: 'POST', body: { service } })).status, 404);
  }
  for (const path of ['/auth/trakt/callback?state=local', '/auth/steam/library', '/games/steam/relay', '/logs']) {
    assert.equal((await f.call(path)).status, 404);
  }
  assert.equal((await f.call('/auth/start', { method: 'POST', body: { service: 'mal' } })).status, 410);
  assert.equal(forwards, 0);
  assert.equal(f.sessions.size, 0); assert.equal(f.admissions.size, 0);
});

test('unconfigured MAL and oversized bodies cannot create state; expiry cleans secrets', async () => {
  const f = fixture(); f.env.MAL_CLIENT_ID = '';
  assert.equal((await f.call('/auth/pkce/start', { method: 'POST', body: { service: 'mal' } })).status, 503);
  f.env.MAL_CLIENT_ID = 'owned-mal';
  assert.equal((await f.call('/auth/pkce/start', { method: 'POST', body: { service: 'mal', padding: 'a'.repeat(1024) } })).status, 413);
  assert.equal(f.admissions.size, 0);
  const s = await f.start(); await s.entry.object.alarm();
  assert.equal(s.entry.ctx.storage.values.size, 0);
  assert.equal((await f.poll(s.session)).status, 410);
  assert.equal(s.expiresIn, TTL_MS / 1000);
});


test('edge start limiter rejects attempts before any object call', async () => {
  const f = fixture(); f.env.START_LIMIT.limit = async () => ({ success: false });
  assert.equal((await f.call('/auth/pkce/start', { method: 'POST', body: { service: 'mal' } })).status, 429);
  assert.equal(f.admissions.size, 0); assert.equal(f.sessions.size, 0);
});

test('declared and streamed oversized bodies reject promptly without state allocation', async () => {
  for (const declared of [true, false]) {
    const f = fixture();
    const body = declared ? 'x'.repeat(1024) : new ReadableStream({
      start(controller) { controller.enqueue(new TextEncoder().encode('x'.repeat(1024))); controller.close(); },
    });
    const request = new Request(`${origin}/auth/pkce/start`, {
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
    const response = await f.call('/auth/pkce/start', { method: 'POST', body: { service: 'mal' }, headers });
    assert.equal(response.status, headers['Content-Type'] ? 415 : 403);
  }
  assert.equal(f.sessions.size, 0); assert.equal(f.admissions.size, 0);
  assert.equal((await f.call('/auth/pkce/start', { method: 'POST', body: { service: 'mal' }, headers: { Origin: origin } })).status, 200);
});

test('client hourly quota survives reload while the global bucket replenishes', async t => {
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
  now += 300_000;
  assert.equal((await reloaded.fetch(req('other-client'))).status, 204);
});

test('edge responses carry no-store, referrer, MIME and frame protections', async () => {
  const f = fixture(); const s = await f.start();
  for (const response of [await f.call('/auth/edge-health'), await f.call('/auth/start'), await f.call('/auth/result', { headers: { Authorization: 'Bearer e1_invalid' } })]) {
    assert.equal(response.headers.get('X-Content-Type-Options'), 'nosniff');
    assert.equal(response.headers.get('Referrer-Policy'), 'no-referrer');
    assert.equal(response.headers.get('X-Frame-Options'), 'DENY');
    assert.match(response.headers.get('Strict-Transport-Security'), /max-age=31536000/);
    assert.match(response.headers.get('Cache-Control'), /no-store/);
  }
});


test('legacy daily admission alarms erase old records without resetting rolling budgets', async () => {
  const oldStorage = new MemoryStorage();
  await oldStorage.put('budget', { count: 100, clients: {} });
  const oldContext = context(oldStorage);
  const oldObject = new OAuthAdmission(oldContext);
  await oldContext.ready;
  await oldObject.alarm();
  assert.equal(oldStorage.values.size, 0);
  const rollingStorage = new MemoryStorage();
  const budget = { tokens: 0, updated: Date.now(), clients: {} };
  await rollingStorage.put('budget', budget);
  const rollingContext = context(rollingStorage);
  const rollingObject = new OAuthAdmission(rollingContext);
  await rollingContext.ready;
  await rollingObject.alarm();
  assert.deepEqual(await rollingStorage.get('budget'), budget);
});
