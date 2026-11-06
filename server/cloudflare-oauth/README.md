# Cloudflare OAuth edge

This Worker hosts MyAnimeList and AniList sign-in independently of the home relay.
It preserves the existing app API and exact registered callback URLs:

- `https://pleazyng-api.snape.tech/auth/mal/callback`
- `https://pleazyng-api.snape.tech/auth/anilist/callback`

Trakt browser PKCE, Steam OpenID/catalog/cloud features, watch parties, uploads,
and other relay features continue on the existing Go origin. Trakt TV sign-in
continues using Trakt's direct device-code API. A hostname on Cloudflare does
not mean every endpoint is hosted there.

## Request routing and compatibility

Cloudflare Worker Route `pleazyng-api.snape.tech/auth/*` selects `pleazyng-oauth`.
DNS continues to point at the existing dedicated Tunnel. The Worker handles:

| Request | Behavior |
| --- | --- |
| `POST /auth/start`, service `mal` or `anilist` | Admit an expiring edge session if that provider is configured |
| `GET /auth/mal` or `/auth/anilist`, edge browser state | Redirect to the fixed provider authorize endpoint |
| Corresponding `/callback`, edge browser state | Claim once and exchange the code at the fixed provider token endpoint |
| `GET /auth/result`, `e1_` device capability | Hold up to 50 seconds, then return 204 or deliver the result once |
| `GET /auth/edge-health` | Non-secret runtime/configuration readiness |
| Trakt, Steam, other paths, old local capabilities | Fetch the existing Tunnel origin unchanged |

Worker Routes allow same-host `fetch(request)` to reach the origin without
recursing into this Worker. Do not replace the Tunnel DNS with a Worker Custom
Domain: that would remove this pass-through origin relationship. Existing local
MAL/AniList sessions may finish through their legacy state/capabilities. The app
continues using `PLEAZYNG_RELAY_BASE_URL=https://pleazyng-api.snape.tech`; no client
update or new callback registration is required for this infrastructure split.

## Storage, cost and limits

There is **no D1 binding, no D1 query, no KV namespace, no per-request database
logging, and no storage write for a pending poll**. The SQLite-backed Durable
Objects store one session record and one small daily admission record. These
are separately metered Durable Objects storage/compute, not an unlimited service.

The defaults deliberately bound admission:

- 100 newly admitted edge sign-in sessions per UTC day, shared by both providers.
- Ten admitted sessions per hashed client IP/UTC day, including cancelled/failed
  attempts. Shared NAT users share this limit; rejected starts do not write state.
- A Workers rate-limit binding permits three start attempts per client/minute
  per Cloudflare location; the admission object also enforces three successful
  admissions per hashed client/minute globally.
- Session lifetime is ten minutes; one outstanding long poll per session.
- Callback is claimed durably before the external token request; replay cannot
  trigger another exchange. Provider fetch timeout is 15 seconds, redirects are
  refused, response size is limited to 64 KiB.
- Pending polls and admission rejections do not write session state. Valid signed
  capabilities are checked before contacting the session object, so fabricated
  object names do not create arbitrary stored sessions.
- Admission, creation, callback claim/completion, result deletion and expiry are
  the bounded write points. Expect a handful of state operations per login,
  rather than writes for every HTTP request. Alarm operations are also metered.

At 100 sessions occupying their entire ten-minute lifetime, session execution
alone is approximately 7,680 GB-s at the documented 128 MiB object allocation.
This is an estimate, not an account-wide guarantee: admission object execution,
retries, attacks, other Workers and Durable Objects share account allowances.
Review aggregate requests, duration, rows written and storage in Cloudflare.
The free plan fails when its limits are exceeded; this deployment does not
upgrade the account or enable paid overages. Raising the daily cap requires a
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
also specified in deployment metadata. Responses are no-store and carry MIME, referrer, frame and HSTS headers; browser pages
have a restrictive CSP and no-referrer policy. The Worker never accepts arbitrary
provider/token URLs. Start bodies are bounded to 512 bytes and oversized streams are cancelled
without waiting on cloned-stream cancellation. MAL/AniList starts require JSON
and reject foreign/null browser Origins and cross-site Fetch Metadata. Native
clients omit Origin; same-origin browser calls remain allowed. These checks apply
only to the migrated providers and do not change Trakt/Steam pass-through.

Token results and PKCE state exist temporarily in the object's encrypted-at-rest
storage until single-use delivery or expiry. They are not a permanent token
vault. Cloudflare storage recovery/retention can outlive application deletion;
expiry is not a claim of immediate physical erasure. Do not add OAuth session
exports to backups. Back up only provider configuration and the signing key
through the approved private secret-backup mechanism. The key/configuration
backup is separate from the application state.

Cloudflare zone protections remain applicable. The local Caddy Knock filter
still protects origin requests, including Trakt/Steam pass-through. Edge-handled
MAL/AniList requests do not pass through local Caddy or its request analytics;
they use the edge admission limits and existing zone controls. There is no
D1-based request-event queue feeding local Knock for these edge requests.

## Configuration and provider activation

| Binding | Purpose |
| --- | --- |
| `PUBLIC_ORIGIN` | Exact public HTTPS origin, without a trailing slash |
| `SESSION_SIGNING_KEY` | Server-only capability signing key; keep stable across normal uploads |
| `MAL_CLIENT_ID` | Owned public MAL client registration; PKCE uses MAL's supported plain challenge |
| `ANILIST_CLIENT_ID`, `ANILIST_CLIENT_SECRET` | Owned AniList registration; secret remains server-side |
| `SESSIONS` | `OAuthSession` SQLite-backed namespace |
| `ADMISSION` | `OAuthAdmission` SQLite-backed namespace |
| `START_LIMIT` | Workers rate limiter, namespace `182791`, three starts/60 seconds |

An absent provider configuration returns 503 before admission or state writes.
A deployed callback is not proof of provider registration, approval or actual
user consent/token exchange. The separate owned-provider registration handoff
records those gates. Keep Trakt's server/client ID configuration independent.

## Test and deploy

Offline regression checks:

```sh
node --test server/cloudflare-oauth/worker.test.mjs
node --check server/cloudflare-oauth/worker.mjs
python3 server/cloudflare-oauth/runtime.test.py --output-dir /task-owned/oauth-runtime-check
```

The tests exercise actual request handlers with instrumented storage: PKCE,
read-only pending polls, a single outstanding poll, single-use delivery,
callback replay/concurrency and cold reload, denial/failure sanitization, expiry,
body limits, daily/IP admission and unchanged Trakt/Steam/legacy pass-through.

Use Wrangler 4.158.0 for a local workerd/SQLite smoke test. Use task-owned state
and output directories, test-only credentials, and a loopback `PUBLIC_ORIGIN`.
Verify that the provider authorize request returns a browser-visible 302 (the
internal Durable Object fetch must use `redirect: manual`). Complete the cancellation callback (`error=access_denied`), retrieve its device
result once and verify the second retrieval returns 410. This tests lifecycle
without accessing a real user's account. Stop the dev server before cleaning
its task-owned SQLite files. Preserve shared package caches.

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
Workers Scripts Edit. The provider file supplies the signing key and available
provider credentials. Use `--initial` only once: it creates migration `v1` with
SQLite classes `OAuthSession` and `OAuthAdmission`. Later uploads omit it and
reuse the same signing key, bindings and object namespaces. Secrets are applied
only as Worker secret bindings, never returned by the helper. Keep the private
provider file and its backup outside Git.

The helper does **not** modify routes. Before attaching the route, inspect the
current route list and Tunnel DNS, verify the uploaded script's bindings and
observability settings, then add only the exact `/auth/*` route to the existing
zone. Route management requires zone Workers Routes Edit separately. Never
replace unrelated routes or import an old account snapshot.

After attachment, check edge health, MAL authorize redirects, a denied callback,
single-use result retrieval, and a replay rejection. Verify local health and
Trakt/Steam paths still reach the origin. Verify the local relay listeners,
firewall rules and unrelated website Workers were not changed. Record source
SHA, deployment ID, route ID, test outcomes and remaining provider gates in the
owner runbook; never retain raw test capabilities or codes in public evidence.

## Rollback and operations

Remove only the route pointing `/auth/*` to `pleazyng-oauth`. Existing DNS/Tunnel
and local Go OAuth handlers resume all requests. Edge sessions will need to
restart sign-in; legacy local sessions can still finish. Do not stop the local
relay, change unrelated DNS, or recreate the whole Tunnel. Keep the Worker and
namespaces for incident investigation unless their destruction is explicitly
intended. Deleting a namespace destroys its stored sessions and quota history.

For source rollback, upload the previously verified source while preserving the
signing key and SQLite namespaces. Rotating the signing key invalidates all
pending edge sessions; document that as a deliberate sign-in interruption.
Provider credentials can be changed independently of app releases. A 429 means
admission or concurrent-poll limits, 410 means expired/consumed/invalid capability,
and 503 means disabled provider or unavailable edge dependency. Do not log a
failed request URL while investigating.

## Security review

See [the dated security review](security-review-20261106.md) for the tested
controls, fixes, provider-specific PKCE compatibility and explicit residual risks.
Login admission limits protect state/compute usage; they do not authenticate an
application or guarantee availability. A distributed attacker can still exhaust
a public free-tier request allowance or the global sign-in cap.
