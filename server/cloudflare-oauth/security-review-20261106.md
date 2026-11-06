# OAuth edge security review — 2026-11-06

Scope: the new Cloudflare Worker, its browser/device capability boundary,
Durable Object session/admission logic, provider HTTP exchange, secret handling,
public route and current zone transport controls. This is a source review plus
focused automated/runtime/live tests, not an independent penetration test of
all relay features, provider accounts, the local OS or the LAN.

## Findings fixed

1. **Oversized declared request bodies could stall rejection.** The initial
   Content-Length rejection occurred before acquiring/cancelling the cloned body
   reader; awaiting cancellation of its other tee branch could then wait
   indefinitely. A local reproducer timed out. Both declared and streamed
   oversize cases now reject with 413, cancelling both branches independently
   without awaiting cancellation. Regression tests impose a bounded deadline;
   the actual workerd test exercises a declared oversized request.
2. **Cross-site browser requests could spend session capacity.** Accepting JSON
   sent as a browser-simple text/plain POST allowed a third-party page to submit
   session starts even though it could not read the response. Edge provider
   starts now require application/json and reject foreign/null Origin and
   cross-site Sec-Fetch-Site. These are pre-admission checks. Native clients
   without Origin and same-origin browser calls still work. Trakt/Steam origin
   forwarding is preserved.
3. **One client could consume the global daily cap over time.** The existing
   three-start/minute burst limit did not prevent one IP from spending all 100
   daily admissions. A persisted ten-admission/client/UTC-day cap now leaves
   capacity for other clients; rejection writes nothing. Existing daily state
   without the new counter is migrated lazily without resetting global usage.
4. **Browser protections were inconsistent across response types.** JSON,
   empty/error and redirect responses now also receive nosniff, no-referrer,
   frame denial and HSTS; browser pages additionally prohibit form submission.

These findings concern availability, unwanted session creation and browser
hardening. The reviewed attack cases did not demonstrate token disclosure,
authentication bypass, arbitrary code execution or access to local private
services. That is a bounded finding, not proof that no other vulnerability exists.

## Controls checked

- Separate random browser and device nonces with role-bound HMAC-SHA256,
  native constant-time signature verification, signed expiry and unpredictable
  session IDs. Browser state cannot authorize device result retrieval.
- Signature validation before a session-object lookup; forged capabilities do
  not create arbitrary persisted session objects.
- Fixed public origin and provider allowlist; request fields cannot select a
  different token endpoint or redirect target. Provider HTTP redirects are
  refused, token exchange times out after 15 seconds, and responses are bounded
  to 64 KiB. Internal object redirects are manual so the browser receives 302.
- Callback claim persists before token exchange; concurrent/replayed callbacks
  cannot exchange another code. Device delivery is single-use, including after
  object reload, with a ten-minute lifetime and expiry cleanup.
- Pending polls do not write storage, and only one outstanding poll is allowed
  per session. Global, per-client/minute and per-client/day admission are bounded.
- No D1/KV binding and no per-request storage logging. Signing/provider secrets
  are server-only bindings; the protected source file is 0600 and its OpenBao
  backup was verified. No provider/session secrets are committed to Git.
- Worker invocation logging/tracing is disabled and query redaction requested.
  HTML never interpolates raw provider errors, codes or capabilities. Responses
  are no-store; token-bearing paths never depend on a shared response cache.
- The live zone uses minimum TLS 1.2, TLS 1.3 enabled, Always Use HTTPS enabled,
  and strict SSL mode. Enabled hostname and scanner-path rules include the API
  hostname. No unrelated zone settings or firewall rules were changed.

MyAnimeList's own documentation currently supports only **plain** PKCE; the
implementation follows that provider requirement. S256 would be stronger and
should be adopted when the provider supports it. Do not silently switch methods
without validating provider compatibility. AniList remains disabled without its
owned client ID/secret; its enabled implementation uses the confidential-client
code exchange with signed state. Trakt browser S256 PKCE remains on the local
Go relay and is outside this edge migration.

Sources: [MAL authorization](https://myanimelist.net/apiconfig/references/authorization),
[OAuth security BCP, RFC 9700](https://www.rfc-editor.org/rfc/rfc9700.html).

## Validation and remaining work

Thirteen instrumented Node tests cover normal exchange and failure paths,
capability separation, forged signatures, cold reload, callback concurrency,
result replay, expiry, body limits, origin/Content-Type checks, admission limits,
security headers and unchanged local-provider forwarding. The real workerd/SQLite
smoke exercises rejected cross-site/plaintext/oversized starts, the provider
302, cancellation and single-use result delivery. The owner runbook records
production source/deployment and the final bounded live checks.

Actual user consent and real provider token issuance have not been qualified.
The public API has no embedded shared client secret and no device attestation:
non-browser clients can omit Origin, and a distributed attacker can still spend
the global cap or the account's public request allowance. IP-based limits can
also affect users behind shared NAT. This protects budgets, not guaranteed
availability or bot-proof identity. No high-volume attack simulation was run.

Tokens/PKCE exist temporarily in Cloudflare's encrypted-at-rest object storage;
application expiry/deletion does not promise immediate physical erasure from
provider recovery retention. Account administrator access and compromise of the
secret store remain trusted boundaries. Existing local relay endpoints and
local Caddy Knock still need their own security maintenance; edge-handled auth
uses zone controls and admission limits, not the local Knock filter.
