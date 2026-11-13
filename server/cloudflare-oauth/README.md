# Cloudflare OAuth code broker

This Worker supports only MyAnimeList's authorization-code handoff. It does not
exchange authorization codes or receive provider access or refresh tokens.
The Flutter app creates and holds MAL's PKCE verifier, builds the provider
authorization URL itself, and exchanges the returned code directly with MAL.
MAL supports only PKCE `plain`, so the challenge is the verifier; the app must
never send that challenge to this Worker.

The registered callback remains
`https://pleazyng-api.snape.tech/auth/mal/callback`. The Worker receives a
single-use authorization code and signed state at that callback, stores the
code briefly for the initiating device, then deletes it after delivery or
expiry. The worker has no AniList client secret and does not handle AniList
token exchange. AniList, Trakt browser, Steam account/capability operations,
uploads, commerce lookups, music control relaying and Steam streaming require a
relay URL the user explicitly configures and operates. The official app ships
with no relay URL.

## Request routing and compatibility

Cloudflare Worker Route `pleazyng-api.snape.tech/*` selects
`pleazyng-oauth` for the entire hostname. Its proxied CNAME remains pointed at
the retired Tunnel target for DNS compatibility, but that connector and the Go
service are stopped. The Worker never calls `fetch(request)` or forwards to an
origin; all requests outside the four Worker endpoints return `404`. It
handles:

| Request | Behavior |
| --- | --- |
| `POST /auth/pkce/start`, service `mal` | Admit a short-lived session and return a fixed MAL authorize URL without a PKCE challenge |
| App opens the MAL authorize URL | The app adds its locally held `plain` verifier as the challenge; the browser goes directly to MAL |
| `GET /auth/mal/callback`, signed browser state | Claim once and store only the authorization code or a sanitized error |
| `GET /auth/result`, `e1_` device capability in `Authorization` | Hold up to 50 seconds, then return 204 or deliver the code-only result once |
| `GET /auth/edge-health` | Non-secret readiness; MAL is the only provider |
| Legacy `POST /auth/start`, service `mal` | Return `410`; the previous first-party token-exchange flow is retired |
| Other `/auth/*` paths and all non-auth paths | Return `404`; never forward to a home origin |

The whole-host route prevents Worker gaps from falling back to the Tunnel. Do
not narrow it to `/auth/*` or restore an origin pass-through. A pre-change
Durable Object result containing tokens is rejected and deleted instead of
being delivered; old pending MAL sessions must restart authorization. The Go
relay source remains available for users to host themselves, but the operator's
home deployment and Tunnel origin are disabled. The official release workflows
do not inject a relay URL.

## Storage, cost and limits

There is **no D1 binding, no D1 query, no KV namespace, no per-request database
logging, and no storage write for a pending poll**. The SQLite-backed Durable
Objects store one session record and one small rolling admission record. These
are separately metered Durable Objects storage/compute, not an unlimited service.

The defaults deliberately bound admission:

- A shared burst of ten new sign-ins, replenishing one slot every 15 minutes.
  Exhaustion recovers continuously instead of blocking all users until midnight.
- Ten admitted sessions per hashed client IP/rolling hour, including cancelled/failed
  attempts. Shared NAT users share this limit; rejected starts do not write state.
- A Workers rate-limit binding permits three start attempts per client/minute
  per Cloudflare location; the admission object also enforces three successful
  admissions per hashed client/minute globally.
- Session lifetime is ten minutes; one outstanding long poll per session.
- Callback is claimed durably before the one-time code is stored; callback
  replay cannot change or replace the result. The Worker makes no provider
  token request.
- Pending polls and admission rejections do not write session state. Valid signed
  capabilities are checked before contacting the session object, so fabricated
  object names do not create arbitrary stored sessions.
- Admission, creation, callback claim/completion, result deletion and expiry are
  the bounded write points. Expect a handful of state operations per login,
  rather than writes for every HTTP request. Alarm operations are also metered.

At the maximum 106 sessions in a 24-hour interval, each occupying their entire ten-minute lifetime, session execution
alone is approximately 8,140.8 GB-s at the documented 128 MiB object allocation.
This is an estimate, not an account-wide guarantee: admission object execution,
retries, attacks, other Workers and Durable Objects share account allowances.
Review aggregate requests, duration, rows written and storage in Cloudflare.
The free plan fails when its limits are exceeded; this deployment does not
upgrade the account or enable paid overages. Raising the rolling allowance requires a
new reviewed source change and a fresh cost estimate.

[Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)
and [Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/)
are the authoritative current allowances. Do not add polling writes or request
logs to D1 to collect usage metrics.

## Security and secret lifecycle

`SESSION_SIGNING_KEY` is a random server-only key of at least 32 bytes. Browser
state and device poll tokens contain separate random nonces and role-bound HMACs;
one cannot be used in the other's endpoint. Only the device receives its poll
capability. Do not log complete URLs, authorization codes, capabilities, tokens,
provider response bodies or configuration values.

Workers invocation logs and traces are disabled, with query-string redaction
also specified in deployment metadata. Responses are no-store and carry MIME,
referrer, frame and HSTS headers; browser pages have a restrictive CSP and
no-referrer policy. The Worker never accepts arbitrary provider/token URLs.
Start bodies are bounded to 512 bytes, accept only the `service` field, and
oversized streams are cancelled without waiting on cloned-stream cancellation.
The callback accepts only the `state`, `code`, and sanitized error parameters;
token-bearing or duplicate query parameters are rejected. Device capabilities
use the `Authorization` header and are rejected in URL queries. The MAL start
requires JSON and rejects foreign Origins and cross-site Fetch Metadata. The
app opens MAL's fixed authorization URL directly; the Worker never sees the
PKCE verifier.

Durable Objects temporarily store state, device poll capabilities, and a
single-use authorization code or sanitized error. They never store provider
tokens in this flow. Results from older token-exchange sessions are rejected
and deleted when polled, and old verifier fields are removed when those
sessions reach the callback. Remaining inactive legacy rows expire after ten
minutes. Cloudflare storage recovery/retention can outlive application
deletion; expiry is not a claim of immediate physical erasure. Do not add OAuth
session exports to backups. Back up only the signing key through the approved
private secret-backup mechanism.

Cloudflare zone protections remain applicable. MAL broker requests use the
edge admission limits and existing zone controls; no first-party request goes
through local Caddy or Knock. User-operated relay deployments have their own
origin and perimeter. There is no D1-based request-event queue feeding local
Knock for these edge requests.

## Configuration and provider activation

| Binding | Purpose |
| --- | --- |
| `PUBLIC_ORIGIN` | Exact public HTTPS origin, without a trailing slash |
| `SESSION_SIGNING_KEY` | Server-only capability signing key; keep stable across normal uploads |
| `MAL_CLIENT_ID` | Public MAL client registration ID; it is not a secret |
| `SESSIONS` | `OAuthSession` SQLite-backed namespace |
| `ADMISSION` | `OAuthAdmission` SQLite-backed namespace |
| `START_LIMIT` | Workers rate limiter, namespace `182791`, three starts/60 seconds |

An absent MAL client ID returns 503 before admission or state writes. A
deployed callback is not proof of provider registration or actual user consent.
The app receives only a code and exchanges it directly with MAL. Trakt's
device-code flow remains direct-to-provider; browser OAuth and other
server-exchanged providers use a user-operated relay.

## Test and deploy

Offline regression checks:

```sh
node --test server/cloudflare-oauth/worker.test.mjs
node --check server/cloudflare-oauth/worker.mjs
python3 server/cloudflare-oauth/runtime.test.py --output-dir /task-owned/oauth-runtime-check
```

The tests exercise actual request handlers with instrumented storage: code-only
callback delivery, absence of verifier/token exchange, rejection of legacy
token results, read-only pending polls, a single outstanding poll, callback
replay/concurrency and cold reload, denial sanitization, expiry, body limits,
rolling/IP admission and 404 rejection without origin pass-through.

Use Wrangler 4.158.0 for a local workerd/SQLite smoke test. Use task-owned state
and output directories, test-only credentials, and a loopback `PUBLIC_ORIGIN`.
Verify that `/auth/pkce/start` returns a fixed MAL authorize URL without a
challenge. Complete the cancellation callback (`error=access_denied`), retrieve
the sanitized result once and verify the second retrieval returns 410. Confirm
that the Worker never calls the MAL token endpoint and rejects a legacy token
result. This tests lifecycle without accessing a real user's account. Stop the
dev server before cleaning its task-owned SQLite files. Preserve shared package
caches.

Commit and push the reviewed source. `deploy.py` uploads the exact committed
`worker.mjs` from the supplied full SHA and refuses a mismatched checkout. It
accepts two **0600** environment files; do not pass secret values as arguments:

```sh
python3 server/cloudflare-oauth/deploy.py \
  --account-env /private/cloudflare-account.env \
  --provider-env /private/pleazyng-oauth.env \
  --source-sha FULL_PUSHED_COMMIT_SHA --initial
```

The account file supplies `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN` with
Workers Scripts Edit. The provider file supplies `SESSION_SIGNING_KEY` and the
public `MAL_CLIENT_ID`; it must not contain AniList client credentials. Use
`--initial` only once: it creates migration `v1` with
SQLite classes `OAuthSession` and `OAuthAdmission`. Later uploads omit it and
reuse the same signing key, bindings and object namespaces. The helper binds
only the signing key as a secret. Keep the private provider file and its backup
outside Git.

The helper does **not** modify routes. Before changing the route, inspect the
current route list and DNS, verify the uploaded script's bindings and
observability settings, then change only the existing Worker route to
`pleazyng-api.snape.tech/*`. Preserve its route ID and script binding. Route
management requires zone Workers Routes Edit separately. Never replace
unrelated routes or import an old account snapshot.

After attachment, check edge health, the MAL authorization URL, a denied
callback, single-use code retrieval, and a replay rejection. Check that `/health`
and `/games/steam/relay` return 404. Stop and disable the operator's Go relay
and Tunnel connector, remove their Caddy route, and replace the Tunnel ingress
with a 404-only catch-all. Preserve the proxied DNS record required by the
whole-host Worker Route. Record source SHA, deployment ID, route ID, test
outcomes and remaining provider gates in the owner runbook; never retain raw
test capabilities or codes in public evidence.

## Rollback and operations

Do not remove or narrow the whole-host Worker route to roll back: an origin
fallback would expose the retired operator-hosted relay again. Roll back only
to a previously verified code-only Worker source while preserving the signing
key and Durable Object namespaces. Edge sessions may need to restart sign-in.
Do not restart the operator's relay or Tunnel connector. Keep the Worker and
namespaces unless their destruction is explicitly intended.
Deleting a namespace destroys pending code sessions and quota history.

For source rollback, upload only a previously verified code-only source while
preserving the signing key and SQLite namespaces. Rotating the signing key
invalidates pending edge sessions; document that as a deliberate sign-in
interruption. A 429 means
admission or concurrent-poll limits, 410 means expired/consumed/invalid capability,
and 503 means disabled provider or unavailable edge dependency. Do not log a
failed request URL while investigating.

## Security review

The [2026-11-06 review](security-review-20261106.md) is a historical record of
the previous architecture. See [the 2026-11-13 review](security-review-20261113.md)
for the current code-only broker, user-hosted relay boundary, and deployment
cutover. Login admission limits protect state/compute usage; they do not
authenticate an application or guarantee availability. A distributed attacker
can still exhaust a public free-tier request allowance or the global sign-in cap.
