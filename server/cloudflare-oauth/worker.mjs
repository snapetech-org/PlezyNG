// OAuth sessions only. No D1/KV namespace and no request/token logging.
const TTL_MS = 600_000;
// Bound paid state creation without a UTC-day availability cliff. A fully
// exhausted bucket admits again in at most 15 minutes, not the next day.
// At most 106 starts in any 24-hour interval: 10 burst + 96 replenishments.
const ADMISSION_BURST = 10;
const ADMISSION_REFILL_MS = 900_000;
const CLIENT_WINDOW_MS = 3_600_000;
const CLIENT_SESSIONS = 10;
const POLL_MS = 50_000;
const EDGE = new Set(['mal']);
const encoder = new TextEncoder();
const SECURITY_HEADERS = Object.freeze({
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'X-Frame-Options': 'DENY',
  'Strict-Transport-Security': 'max-age=31536000',
});
class PayloadTooLarge extends Error {}
function discardBody(request) {
  // Cancellation of a cloned (tee'd) stream can wait for its other branch.
  // Never await it on the response path; cancel both branches independently.
  try { void request.body?.cancel().catch(() => {}); } catch {}
}
const json = (value, status = 200, headers = {}) => new Response(JSON.stringify(value), {
  status, headers: { ...SECURITY_HEADERS, 'Content-Type': 'application/json', 'Cache-Control': 'no-store, private', ...headers },
});
const empty = status => new Response(null, { status, headers: { ...SECURITY_HEADERS, 'Cache-Control': 'no-store, private' } });
const hex = bytes => [...bytes].map(v => v.toString(16).padStart(2, '0')).join('');
const random = () => hex(crypto.getRandomValues(new Uint8Array(16)));
const configured = (env, service) => service === 'mal' && !!env.MAL_CLIENT_ID;
const base = env => env.PUBLIC_ORIGIN || 'https://pleazyng-api.snape.tech';

async function key(env) {
  if (!env.SESSION_SIGNING_KEY || env.SESSION_SIGNING_KEY.length < 32) throw new Error('missing signing key');
  return crypto.subtle.importKey('raw', encoder.encode(env.SESSION_SIGNING_KEY), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify']);
}
async function mac(env, value) {
  return hex(new Uint8Array(await crypto.subtle.sign('HMAC', await key(env), encoder.encode(value))));
}
async function capability(env, role, id, expires) {
  const value = `${id}_${expires}_${random()}`;
  return `e1_${value}_${await mac(env, `${role}|${value}`)}`;
}
async function verify(env, role, token) {
  const match = /^e1_([a-f0-9]{32})_([0-9]{13})_([a-f0-9]{32})_([a-f0-9]{64})$/.exec(token || '');
  if (!match || Number(match[2]) <= Date.now() || Number(match[2]) > Date.now() + TTL_MS) return null;
  const bytes = Uint8Array.from(match[4].match(/../g), part => parseInt(part, 16));
  const value = `${match[1]}_${match[2]}_${match[3]}`;
  if (!await crypto.subtle.verify('HMAC', await key(env), bytes, encoder.encode(`${role}|${value}`))) return null;
  return { id: match[1], expires: Number(match[2]) };
}
function session(env, id) { return env.SESSIONS.get(env.SESSIONS.idFromName(id)); }
function internal(path, body) {
  return new Request(`https://session.internal/${path}`, body === undefined ? { redirect: 'manual' } : { method: 'POST', body: JSON.stringify(body), redirect: 'manual' });
}
function page(ok, status = 200) {
  // Static text only; never interpolate provider responses, state or codes.
  const title = ok ? 'Signed in to Pleazyng' : 'Sign-in could not be completed';
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${title}</title><body><h1>${title}</h1><p>Return to the app. You can close this tab.</p></body></html>`, {
    status, headers: { ...SECURITY_HEADERS, 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store, private',
      'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'", 'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff' },
  });
}
async function limitedText(request, limit) {
  if (Number(request.headers.get('Content-Length')) > limit) { discardBody(request); throw new PayloadTooLarge(); }
  const reader = request.body?.getReader();
  if (!reader) return '';
  let total = 0; const parts = [];
  while (true) {
    const { done, value } = await reader.read(); if (done) break;
    total += value.length;
    if (total > limit) { void reader.cancel().catch(() => {}); throw new PayloadTooLarge(); }
    parts.push(value);
  }
  const bytes = new Uint8Array(total); let offset = 0;
  for (const part of parts) { bytes.set(part, offset); offset += part.length; }
  return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.origin !== base(env)) return empty(404);
    try {
      if (url.pathname === '/auth/edge-health') return request.method === 'GET'
        ? json({ ok: true, runtime: 'cloudflare', d1: false, providers: { mal: configured(env, 'mal'), anilist: false }, flow: 'code-only-pkce', admissionBurst: ADMISSION_BURST, admissionRefillSeconds: ADMISSION_REFILL_MS / 1000 }) : empty(405);
      if (url.pathname === '/auth/pkce/start' && request.method !== 'POST') return empty(405);
      if (url.pathname === '/auth/pkce/start' && request.method === 'POST') {
        let body;
        try { body = JSON.parse(await limitedText(request.clone(), 512)); } catch (error) {
          discardBody(request); return empty(error instanceof PayloadTooLarge ? 413 : 400);
        }
        if (!body || typeof body !== 'object' || Array.isArray(body) || Object.keys(body).some(name => name !== 'service')) return empty(400);
        if (body.service !== 'mal') return empty(404);
        const contentType = (request.headers.get('Content-Type') || '').split(';')[0].trim().toLowerCase();
        if (contentType !== 'application/json') return empty(415);
        const origin = request.headers.get('Origin');
        if ((origin !== null && origin !== base(env)) || request.headers.get('Sec-Fetch-Site') === 'cross-site') return empty(403);
        if (!configured(env, 'mal')) return json({ error: 'provider_not_configured' }, 503);
        const ip = request.headers.get('CF-Connecting-IP');
        if (!ip) return empty(400);
        const day = new Date().toISOString().slice(0, 10);
        const client = await mac(env, `admission|${day}|${ip}`);
        if (!env.START_LIMIT || !(await env.START_LIMIT.limit({ key: client })).success) {
          return json({ error: 'login_rate_limited' }, 429, { 'Retry-After': '60' });
        }
        const admission = await env.ADMISSION.get(env.ADMISSION.idFromName('rolling-v2')).fetch(internal('admit', { client }));
        if (!admission.ok) return admission;
        const id = random(); const expires = Date.now() + TTL_MS;
        const browser = await capability(env, 'browser', id, expires);
        const poll = await capability(env, 'device', id, expires);
        const created = await session(env, id).fetch(internal('start', { service: 'mal', expires, browser }));
        if (!created.ok) return created;
        const redirectUri = `${base(env)}/auth/mal/callback`;
        const authorize = new URL('https://myanimelist.net/v1/oauth2/authorize');
        authorize.search = new URLSearchParams({ response_type: 'code', client_id: env.MAL_CLIENT_ID, redirect_uri: redirectUri, state: browser });
        // The app adds its locally-held plain PKCE verifier to this URL. Never
        // send the challenge to this Worker: MAL only supports `plain`.
        return json({ session: poll, url: authorize.toString(), redirectUri, expiresIn: TTL_MS / 1000 });
      }
      if (url.pathname === '/auth/start') {
        if (request.method !== 'POST') return empty(405);
        let body;
        try { body = JSON.parse(await limitedText(request.clone(), 512)); } catch (error) {
          discardBody(request); return empty(error instanceof PayloadTooLarge ? 413 : 400);
        }
        // All provider flows that deliver tokens require a relay operated by
        // the user. The first-party MAL flow uses /auth/pkce/start.
        if (body?.service === 'mal') return json({ error: 'code_only_authorization_required' }, 410);
        return empty(404);
      }
      if (url.pathname === '/auth/result') {
        if (request.method !== 'GET') return empty(405);
        if (url.search) return empty(400);
        const match = /^Bearer (.+)$/i.exec((request.headers.get('Authorization') || '').trim());
        const verified = await verify(env, 'device', match?.[1]);
        if (!verified) return empty(410);
        return session(env, verified.id).fetch(internal('result'));
      }
      if (url.pathname === '/auth/mal/callback' && request.method !== 'GET') return empty(405);
      if (url.pathname === '/auth/mal/callback') {
        if (request.method !== 'GET') return empty(405);
        const allowedParameters = new Set(['state', 'code', 'error', 'error_description']);
        const parameterNames = [...url.searchParams.keys()];
        if (parameterNames.some(name => !allowedParameters.has(name)) ||
          parameterNames.some(name => url.searchParams.getAll(name).length !== 1) ||
          !url.searchParams.has('state') ||
          url.searchParams.has('code') === url.searchParams.has('error') ||
          (url.searchParams.has('error_description') && !url.searchParams.has('error')) ||
          (url.searchParams.has('code') && (!url.searchParams.get('code') || url.searchParams.get('code').length > 4096))) return empty(400);
        const token = url.searchParams.get('state');
        // MAL callbacks for old full-exchange sessions must not fall back to
        // the origin. The code-only broker creates a fresh signed state.
        const verified = await verify(env, 'browser', token);
        if (!verified) return page(false, 404);
        return session(env, verified.id).fetch(internal('callback', {
          service: 'mal', code: (url.searchParams.get('code') || '').slice(0, 4096),
          error: url.searchParams.has('error') ? (url.searchParams.get('error') === 'access_denied' ? 'access_denied' : 'authorization_failed') : '',
        }));
      }
      // This hostname is a code-only OAuth broker. Never proxy requests to the
      // home relay, including unknown routes that an older app may request.
      return empty(404);
    } catch {
      // Do not log exception text: fetch errors can include capability URLs.
      return json({ error: 'oauth_unavailable' }, 503);
    }
  },
};

export class OAuthAdmission {
  constructor(ctx) {
    this.ctx = ctx;
    ctx.blockConcurrencyWhile(async () => { this.data = await ctx.storage.get('budget') || { tokens: ADMISSION_BURST, updated: Date.now(), clients: {} }; });
  }
  async fetch(request) {
    const { client } = await request.json(); const now = Date.now();
    if (typeof client !== 'string' || client.length > 128 || !client) return empty(400);
    const tokens = Math.min(ADMISSION_BURST, this.data.tokens + Math.max(0, now - this.data.updated) / ADMISSION_REFILL_MS);
    const previous = this.data.clients[client] || [];
    const active = previous.filter(time => time > now - CLIENT_WINDOW_MS);
    const recent = active.filter(time => time > now - 60_000);
    const wait = Math.max(tokens < 1 ? (1 - tokens) * ADMISSION_REFILL_MS : 0,
      recent.length >= 3 ? recent[0] + 60_000 - now : 0,
      active.length >= CLIENT_SESSIONS ? active[0] + CLIENT_WINDOW_MS - now : 0);
    if (wait > 0) return json({ error: 'login_rate_limited' }, 429, { 'Retry-After': String(Math.max(1, Math.ceil(wait / 1000))) });
    this.data.tokens = tokens - 1; this.data.updated = Math.max(now, this.data.updated);
    this.data.clients = Object.fromEntries(Object.entries(this.data.clients).filter(([, times]) => times.at(-1) > now - CLIENT_WINDOW_MS));
    this.data.clients[client] = [...active, now];
    await this.ctx.storage.put('budget', this.data);
    // No deletion alarm: deleting a rolling budget would reset its allowance.
    // Client history is pruned at admission and bounded by the global budget.
    return empty(204);
  }
  async alarm() {
    // Legacy day-named objects still have expiry alarms after an upgrade.
    // Only the new rolling object must retain its budget across idle periods.
    if (!Number.isFinite(this.data.tokens)) await this.ctx.storage.deleteAll();
    await this.ctx.storage.deleteAlarm();
  }
}

export class OAuthSession {
  constructor(ctx, env) {
    this.ctx = ctx; this.env = env; this.waiter = null;
    ctx.blockConcurrencyWhile(async () => { this.data = await ctx.storage.get('session'); });
  }
  async fetch(request) {
    const action = new URL(request.url).pathname;
    if (action === '/start') {
      if (this.data) return empty(409);
      const { service, expires, browser } = await request.json();
      if (this.data) return empty(409);
      if (!EDGE.has(service) || !Number.isSafeInteger(expires) || expires <= Date.now() || expires > Date.now() + TTL_MS) return empty(400);
      this.data = { service, expires, browser, claimed: false, result: null };
      await this.ctx.storage.put('session', this.data);
      await this.ctx.storage.setAlarm(expires);
      return empty(204);
    }
    if (!this.data || this.data.expires <= Date.now() || this.data.consumed) return empty(410);
    if (action === '/result') return this.poll();
    const body = await request.json();
    if (body.service !== this.data.service) return empty(404);
    if (action !== '/callback') return empty(404);
    if (this.data.claimed) return page(false, 404);
    this.data.claimed = true;
    await this.ctx.storage.put('session', this.data); // Persist the one-use callback claim before storing its code.
    let result; let status = 200;
    if (body.error) result = { error: body.error };
    else if (!body.code) { result = { error: 'missing_code' }; status = 400; }
    else result = { authorizationCode: body.code };
    if (!this.data || this.data.consumed || this.data.expires <= Date.now()) return page(false, 410);
    delete this.data.verifier; // Remove verifier material from sessions created by the retired exchange flow.
    this.data.browser = ''; this.data.result = result;
    await this.ctx.storage.put('session', this.data);
    this.waiter?.();
    return page(!result.error, status);
  }
  async poll() {
    if (this.waiter) return json({ error: 'poll_in_progress' }, 429, { 'Retry-After': '2' });
    if (!this.data.result) {
      let timer;
      try {
        await new Promise(resolve => { this.waiter = resolve; timer = setTimeout(resolve, Math.min(POLL_MS, this.data.expires - Date.now())); });
      } finally { clearTimeout(timer); this.waiter = null; }
    }
    if (!this.data || this.data.consumed || this.data.expires <= Date.now()) return empty(410);
    if (!this.data.result) return empty(204); // No storage writes on pending polls.
    const result = this.data.result;
    const codeOnly = result && typeof result === 'object' && (
      (Object.keys(result).length === 1 && typeof result.authorizationCode === 'string') ||
      (Object.keys(result).length === 1 && typeof result.error === 'string')
    );
    if (!codeOnly) {
      // Never return a token result retained by a pre-code-only deployment.
      this.data = null;
      await this.ctx.storage.deleteAll();
      await this.ctx.storage.deleteAlarm();
      return empty(410);
    }
    this.data.consumed = true; this.data.result = null;
    await this.ctx.storage.deleteAll();
    await this.ctx.storage.deleteAlarm();
    return json(result); // One device receives the code-only result, once.
  }
  async alarm() {
    if (this.data) { this.data.consumed = true; this.data.result = null; this.data.browser = ''; }
    await this.ctx.storage.deleteAll(); this.waiter?.();
  }
}
