# Audit remediation — 2026-11-09

Audit baseline: `da2909290f6a2ad8dcb3378be9395c97bd0914a2`. This ledger distinguishes code changes, executed checks and remaining operational/architectural work. It does not claim a complete platform certification.

## Findings

| ID | Status | Change and remaining boundary |
| --- | --- | --- |
| PLY-01 | Implemented; Python verified | Worker-owned TLS handshake timeout; raw listening socket; bounded workers. |
| PLY-02 | Implemented; Dart CI pending | 16 MiB default bounded accumulation for JSON/tracker helpers; reject declared and streamed oversize. |
| PLY-03 | Implemented; Dart CI pending | Abort and cancel artwork error bodies before releasing concurrency slots. |
| PLY-04 | Implemented; Dart CI pending | Cancel failed downloads under the receive deadline instead of draining arbitrary bodies. |
| PLY-05 | Implemented; Dart CI pending | Apply the poster upload ceiling inside getBytes before Content-Length allocation. |
| PLY-06 | Mitigated; Node verified | Rolling global burst/refill with durable hourly client quotas replaces the shared UTC-day lockout. Distributed denial remains possible for a public endpoint; deploy the Worker change separately. |
| PLY-07 | Implemented; Go race verified | Coalesce same-key lookups, bound distinct in-flight fetches, provider-wide burst/refill, and cache failures. Limits are per process; deployment replicas multiply allowance. |
| PLY-08 | Implemented; Dart CI pending | Reject absolute initial targets outside an authenticated client base origin before attaching its default headers. |
| PLY-09 | Implemented; Dart CI pending | Owned abort signals, header/body deadlines, late-response cancellation, unclaimed-response expiry and close-time abort. |
| PLY-10 | Implemented; Dart CI pending | Bound PUT replies to 64 KiB and GET to 4 MiB with whole-request cancellation and owner checks. |
| PLY-11 | Implemented compatibility policy; device qualification pending | HTTPS available for Wi-Fi transfer, stream-out and karaoke. HTTP requires explicit session consent; it remains plaintext by design when selected. Certificates must be trusted by receivers; no TLS-error downgrade. |
| PLY-12 | Implemented; Dart/FFmpeg CI pending | Retain successful encoder output for five minutes after EOF so lagging clients can finish. |
| PLY-13 | Implemented; Dart/FFmpeg CI pending | Renew the one-hour idle lease on authorized requests, with an explicit 24-hour absolute cap and fixed EOF grace. |
| PLY-14 | Implemented; Dart CI pending | Random 128-bit salts and PBKDF2-HMAC-SHA256, 210,000 iterations; constant-time comparison; durable attempt throttling; legacy upgrade during successful activation. Four digits remain a local parental control, not strong account authentication. |
| PLY-15 | Implemented; Dart CI pending | Add MDBList to Android and Dart system-authority-only API domains. |
| PLY-16 | Implemented for new writes; legacy migration remains | AES-256-GCM authenticated envelopes bind logical key and OS key identity, authenticate the complete stored value list, and use a distinct OS-key namespace to reject CBC downgrade; random data key is wrapped by webOS keymanager. Existing CBC rows remain readable and upgrade on write. Real webOS key-service qualification and migration of untouched legacy rows remain. |
| PLY-17 | Partially mitigated; architectural work remains | Native shutdown no longer traps the exit UI; files and native lease remain owned until real acknowledgment. Native cores still run in-process: process isolation, sandbox policy and platform-specific recovery are not implemented. |
| PLY-18 | Implemented; Dart CI pending | Bounded recursive redaction of serialized Sentry events, nested maps/lists/keys; drop event on serialization/redaction failure. |
| PLY-19 | Partially implemented; administrator action remains | Automatic main-branch hosted security checks added. Required checks and branch protection still need repository administration; public PRs must use the owner-mandated isolated restricted-egress sandbox. |
| PLY-20 | Implemented; CI resolution pending | Root CI dependency resolution now enforces pubspec.lock. |
| PLY-21 | Implemented; scheduled execution pending | Weekly Dependabot across Actions, Pub packages, Go, npm and Python requirements; scheduled Go vulnerability scan. Native vendored sources still require owner maintenance. |
| PLY-22 | Implemented; Python verified | Mock release qualification and assert the intended failure before dispatch; never invoke gh on a real run from this unit test. |
| PLY-23 | Guard added; translation work remains | Freeze the reviewed fallback ceiling at 1,244 keys / 44,784 locale entries. No machine-generated strings are represented as reviewed translations. |
| PLY-24 | Blocked on authentic release trust material | Keep remote catalog updates fail-closed. Do not invent production signing keys; pin only the actual owner-reviewed immutable active MilkRust root. |
| PLY-25 | Implemented; Python verified | Header deadline before parsing, bounded worker slots, and forwarded-client headers accepted only from loopback reverse proxy. |

## Qualification backlog

These acceptance items require the specified devices, test accounts, provider approvals or environments. They remain open until evidence is recorded; existing product features and experiments remain available under their established runtime controls.

- **Q01 — Full application qualification**: open; see the original audit for acceptance scope.
- **Q02 — Profile/session race acceptance**: open; see the original audit for acceptance scope.
- **Q03 — Backup/restore durability**: open; see the original audit for acceptance scope.
- **Q04 — Two-device sync and shared book identity**: open; see the original audit for acceptance scope.
- **Q05 — Discovery and recommendation acceptance**: open; see the original audit for acceptance scope.
- **Q06 — Publication and browser interoperability**: open; see the original audit for acceptance scope.
- **Q07 — Connected-source interoperability and scale**: open; see the original audit for acceptance scope.
- **Q08 — Download and index recovery**: open; see the original audit for acceptance scope.
- **Q09 — Purchase-entitlement acceptance**: open; see the original audit for acceptance scope.
- **Q10 — Steam receiver and optional service acceptance**: open; see the original audit for acceptance scope.
- **Q11 — RomM cores, saves and package signing**: open; see the original audit for acceptance scope.
- **Q12 — Multiview platform and unfinished surface scope**: open; see the original audit for acceptance scope.
- **Q13 — Dolby Vision, FEL and acceleration experiments**: open; see the original audit for acceptance scope.
- **Q14 — Visualizer runtime and formats**: open; see the original audit for acceptance scope.
- **Q15 — Lending activation and provider boundaries**: open; see the original audit for acceptance scope.
- **Q16 — Karaoke acceptance and remaining product scope**: open; see the original audit for acceptance scope.
- **Q17 — LG and Samsung TV qualification**: open; see the original audit for acceptance scope.
- **Q18 — Accessibility and language quality**: open; see the original audit for acceptance scope.
- **Q19 — Deployment and supply-chain evidence**: open; see the original audit for acceptance scope.
- **Q20 — Reconcile implementation and qualification records**: open; see the original audit for acceptance scope.

## Executed validation

- Go server and healthcheck: `go test -race ./...` passed; upstream coalescing, cancellation, failure cache and refill regressions included.
- Cloudflare Worker: 14 tests passed.
- Lending gateway: 10 tests passed, including slow headers and exhausted workers.
- Karaoke companion TLS regression passed; optional analysis dependencies remain uninstalled locally.
- Workflow security/action-pin checks and locale structural/source checks passed. The broader Python checker suite ran 572 tests: 557 passed, 13 skipped and two failed solely because local Dart was unavailable. Hosted Go vulnerability scanning also passed.
- Clean hosted Flutter 3.47.1 resolved the enforced lockfile and completed analysis; its initial two lint diagnostics were corrected. Runtime regression execution is pending the updated hosted run. The local SDK bootstrap was rejected by automatic approval review; it was not retried or bypassed.

Deployment changes are not live merely because source is committed. Apply the Worker and gateway/server changes through their existing deployment runbooks, preserving sessions, provider secrets, route bindings and rollback artifacts.
