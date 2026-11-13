# Pleazyng service security review — 2026-11-12

## Scope and confidence

This was a source and hosting configuration review of the Go relay, the
Cloudflare OAuth Worker boundary, Flutter service clients and credential
storage, plus the systemd and Docker deployment definitions. Confidence is
**moderate** for the reviewed source and configuration. This is not an
independent penetration test, a review of every Flutter feature, or a live
provider-consent qualification.

The deployed edge Worker has a separate focused review at
[`cloudflare-oauth/security-review-20261106.md`](cloudflare-oauth/security-review-20261106.md).

## Findings fixed in this change

| Finding | Risk | Change |
| --- | --- | --- |
| The anonymous `/relay` WebSocket accepted every browser `Origin`. | A hostile site could make a visitor's browser open a relay connection and consume that visitor's connection and message quotas. This did not bypass account authentication because this relay has no cookie-authenticated identity. | Browser origins now must exactly match the configured allowlist. Native clients without `Origin` remain supported. The default list is `https://pleazyng.app` and `https://www.pleazyng.app`. |
| Anonymous `/logs` and `/posters` writes accepted cross-site browser POSTs. | A hostile page could spend a visitor's source-IP upload/storage quotas and add untrusted content to the shared short-lived artifact store. | These writes use the same exact-origin policy before reading or storing request bodies. Existing size, rate, concurrency, per-source, expiry, and total-store limits remain in force. |
| Steam and Music WebSocket checks used `Header.Get("Origin") == ""`. | Multiple `Origin` headers with an empty first value could pass the early check and the WebSocket upgrader's origin callback. | Both routes now require that no `Origin` header value exists. The Steam relay still requires its signed admission and bearer capability. |
| Poster responses relied on the image MIME type without `nosniff`. | Browsers could attempt content sniffing on uploaded bytes. | Poster downloads now return `X-Content-Type-Options: nosniff`; upload MIME detection admits JPEG, PNG, GIF, and WebP only. |
| Diagnostic upload safety depended on every caller passing redacted text. | A future callsite could accidentally upload a raw credential-bearing string. | The upload service now reapplies the app's secret redactor immediately before sending; current callers continue to supply their safe, selected diagnostic content. |
| `Gemfile.lock` pinned Addressable 2.9.0, covered by three open moderate advisories. | Affected URI parsing can trigger regex denial of service or resolve some dotted path segments incorrectly in Fastlane tooling. | Updated the locked gem to 2.9.1, the first patched release reported by GitHub Dependabot. |
| The Docker Compose deployment did not make the container root filesystem read-only or drop default capabilities. | A service compromise had a larger writable and privileged container surface than needed. | Compose now uses a read-only root, a bounded `/tmp`, no added capabilities, no-new-privileges, 0.5 CPU, 128 MiB memory, and 64 processes. State remains on its `/data` volume. |

The systemd source unit in `snape.local/pleazyng-relay/` also adds namespace,
procfs, kernel, personality, realtime, SUID/SGID, and executable-memory
restrictions. The primary deployment already uses `DynamicUser`, a private
0700 state directory, loopback binding, an empty capability bounding set,
`NoNewPrivileges`, strict filesystem protection, and resource caps. The new
unit directives need live `systemd-analyze verify` and service qualification
when deployed.

## App and edge boundaries

- The Flutter OAuth client accepts only HTTPS service URLs and rejects the
  upstream Plezy-owned domains. Stored provider credentials are AES-GCM
  encrypted in the app database; key material stays in the platform credential
  store. See `lib/services/plezy_server.dart` and
  `lib/services/credential_vault.dart`.
- Diagnostic logs pass through the redaction manager when recorded and are
  redacted again at the upload boundary. Startup failure uploads use a bounded
  allowlist of fields and do not include preferences, database rows, or files.
- The shipped Watch Together client uses the Open Watch Party public relay set
  by default and an optional relay using that protocol. The Go `/relay` route
  does not appear as a maintained Dart callsite in this source tree. Steam and
  Music Connect use their separate capability-protected WebSocket paths.
- MAL/AniList OAuth is handled by the dedicated Worker route. Other API paths
  remain on the home Tunnel and Go service. The `snape.tech` rate-limit rule
  now includes `pleazyng-api.snape.tech` at 480 requests per 10 seconds per
  source IP and Cloudflare colo; the Worker and origin apply tighter endpoint
  quotas.
- The origin remains behind an outbound-only Cloudflare Tunnel, Caddy's
  Knock-filtered loopback listener, and a Go listener bound to loopback. The
  systemd service and Tunnel remain primary-only; this does not provide
  application failover.

## Residual risks and validation

- Origin checks constrain browsers; they are not authentication and can be
  omitted or forged by non-browser clients. The intentionally anonymous relay
  and artifact endpoints therefore still rely on their admission, rate,
  concurrency, storage, and expiry limits. Distributed request floods and
  Cloudflare/account-level availability events remain possible.
- The shared Cloudflare rate rule uses a relatively high common threshold to
  preserve existing Authentik, Immich, Snape, and Dune behavior. It is an outer
  ceiling, not a per-endpoint quota.
- Uploaded raster files are served as supplied rather than decoded and
  re-encoded. `nosniff` prevents MIME guessing, but image decoder vulnerabilities
  in client platforms remain a separate risk.
- The exact-origin allowlist defaults to the two Pleazyng production web
  origins. Self-hosted browser clients must configure their own exact origins;
  native clients that omit `Origin` do not need a change.
- Regression tests were added for origin policy, cross-site writes, duplicate
  Origin headers, and poster response headers. Their validation and deployment
  status is recorded in the follow-up below.
- No full device matrix, provider account consent, external penetration test,
  or distributed-denial-of-service exercise was performed.

## Follow-up: shared relay abuse controls — 2026-11-13

The follow-up source change adds a shared 120-request burst / 30-request-per-
second HTTP limit, source-controlled failure tracking across endpoints, and
per-address WebSocket handshake and frame limits. Ten marked violations within
15 minutes now cause a 15-minute ban; later bans within 30 days escalate to
one hour and then 24 hours. Active bans are checked on each incoming relay
frame and across new HTTP/WebSocket requests. The abuse-state file in the
systemd state directory stores only keyed HMAC source hashes and ban
expiry/level information; its key and state file are owner-only, and a missing
key beside existing state prevents startup.

This IP-based control can affect other users sharing a NAT address or IPv6
`/64`. The caps bound memory and persistence growth. It does not replace the
Cloudflare edge ceiling or mitigate distributed floods. Regression tests cover
aggregate relay limits, escalation, persistence, missing-key behavior, marked
endpoint limits, and the health-check exception.

## Follow-up: validation and deployment — 2026-11-13

The Go server security job passed in GitHub Actions run `43345834708` on
revision `365964ec848e6577994d909653f7b9d882e0e0f1`. Go source files are
unchanged from that tested revision through the deployed source
`bbcb7e881bc21f92353a5fc8270fc21ea7e6e241` and latest `main` at
`26c04cab5ecda768b0fe776681a3f86f57575166`.

The full Dart suite on the earlier tested revision later completed with 11,299
passed, 2 failed, and 22 skipped. One failure found that a second diagnostic
redaction pass changed `[REDACTED_TOKEN]` into `[REDACTED]]`; the other was a
map-type error in the subtitle validation test fixture. Both were fixed in
source commit `bbcb7e881` (preserve existing redaction markers and correct the
fixture). The fixes are present on `main` at
`26c04cab5ecda768b0fe776681a3f86f57575166`. Its full Security regressions
workflow run `43351852530` was pending at 02:23 UTC; a complete post-fix suite
pass is not yet confirmed.

The Go relay is deployed as a versioned, static Linux amd64 binary from that
source revision. The systemd unit passed `systemd-analyze verify`; after
restart, the service was active, local and public health returned HTTP 200,
and the public `/relay` route returned HTTP 101 for a WebSocket upgrade. The
upgrade probe sent no frame, so it did not verify a complete create/join/leave
session. Listeners remain loopback-only. The abuse-state key is mode 0600; raw
client IPs are not persisted. Binary and unit hashes, rollback artifact, and
the bounded verification receipt are recorded in
[`snape.local`](https://github.com/snapetech-org/snape.local/blob/main/pleazyng-relay/qualification-20261113.json).

Cloudflare firewall ruleset version 16 excludes `pleazyng-api.snape.tech`
from the selected-country block so users in those regions can reach the relay.
The selected-country block still covers the other configured internal hosts;
Cloudflare-hosted Pleazyng and Snape sites remain outside that hostname set.
The API's existing 480 requests per 10 seconds per source IP and Cloudflare
colo limit remains enabled, along with the scanner/exploit-path rule. No AX11000
router geo policy was changed. `/auth/*` remains on the Cloudflare Worker;
other relay paths remain on the Tunnel to the loopback Go origin.

The full Dart suite, complete live WebSocket room lifecycle, provider-account
consent, external penetration test, and distributed-flood exercise were not
qualified by this deployment check. The Tunnel and relay remain primary-only.
