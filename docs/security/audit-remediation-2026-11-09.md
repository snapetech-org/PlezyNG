# Audit remediation — 2026-11-09

Audit baseline: `da2909290f6a2ad8dcb3378be9395c97bd0914a2`. This ledger distinguishes code changes, executed checks and remaining operational/architectural work. It does not claim a complete platform certification.

## Findings

| ID | Status | Change and remaining boundary |
| --- | --- | --- |
| PLY-01 | Implemented; Python verified | Worker-owned TLS handshake timeout; raw listening socket; bounded workers and absolute HTTP header deadline resistant to drip-fed traffic. |
| PLY-02 | Implemented; Dart regressions verified | 16 MiB default bounded accumulation for JSON/tracker helpers; reject declared and streamed oversize. |
| PLY-03 | Implemented; Dart regressions verified | Abort and cancel artwork error bodies before releasing concurrency slots. |
| PLY-04 | Implemented; Dart regressions verified | Cancel failed downloads under the receive deadline instead of draining arbitrary bodies. |
| PLY-05 | Implemented; Dart regressions verified | Apply the poster upload ceiling inside getBytes before Content-Length allocation. |
| PLY-06 | Mitigated; Node verified | Rolling global burst/refill with durable hourly client quotas replaces the shared UTC-day lockout. Distributed denial remains possible for a public endpoint; deploy the Worker change separately. |
| PLY-07 | Implemented; Go race verified | Coalesce same-key lookups, bound distinct in-flight fetches, provider-wide burst/refill, and cache failures. Limits are per process; deployment replicas multiply allowance. |
| PLY-08 | Implemented; Dart regressions verified | Reject absolute initial targets outside an authenticated client base origin before attaching its default headers. Plex Discover and EPG calls use fixed cloud-origin clients with independently owned cancellation and current request credentials; cloud failures cannot change media-server failover state. |
| PLY-09 | Implemented; Dart regressions verified | Owned abort signals, header/body deadlines, late-response cancellation, unclaimed-response expiry and close-time abort. |
| PLY-10 | Implemented; Dart regressions verified | Bound PUT replies to 64 KiB and GET to 4 MiB with whole-request cancellation and owner checks. |
| PLY-11 | Implemented compatibility policy; device qualification pending | HTTPS available for Wi-Fi transfer, stream-out and karaoke. HTTP requires explicit session consent; it remains plaintext by design when selected. Certificates must be trusted by receivers; no TLS-error downgrade. |
| PLY-12 | Implemented; Dart/FFmpeg verified | Retain successful encoder output for five minutes after EOF so lagging clients can finish. |
| PLY-13 | Implemented; Dart/FFmpeg verified | Renew the one-hour idle lease on authorized requests, with an explicit 24-hour absolute cap and fixed EOF grace. |
| PLY-14 | Implemented; Dart regressions verified | Random 128-bit salts and PBKDF2-HMAC-SHA256, 210,000 iterations; constant-time comparison; durable attempt throttling; legacy upgrade during successful activation. Four digits remain a local parental control, not strong account authentication. |
| PLY-15 | Implemented; Dart regressions verified | Add MDBList to Android and Dart system-authority-only API domains. |
| PLY-16 | Implemented; startup migration regressions verified | AES-256-GCM authenticated envelopes bind logical key and OS key identity, authenticate the complete stored value list, and use a distinct OS-key namespace to reject CBC downgrade; random data key is wrapped by webOS keymanager. Unwrap, decoding and authentication failures expose one non-destructive error to avoid a distinguishable CBC padding-error oracle. Writes reject values above 4 MiB or logical keys above 1 KiB of UTF-8 before key allocation, keeping every new envelope inside the reader limit. Startup explicitly migrates every untouched CBC entry and the index in one compare-and-store transaction before connections load credentials. Conflicts reload; pre-commit failures preserve the old row; lost acknowledgements retain staged keys for recovery. Ordinary reads remain non-mutating. Real webOS key-service qualification remains. |
| PLY-17 | Unsafe fallback removed; desktop and Android emulator containment verified | Desktop cores execute in a separate sandboxed worker through bounded, deadline-controlled IPC. Android now uses a private isolated-UID service with read-only input descriptors and a virtual filesystem. Every platform requires isolation ABI 1 and fails closed on an old host. Builds without an isolated helper link an unavailable host that never loads cores. Saves and audio stay parent-owned; session files remain leased until OS-confirmed termination. Policies, tests and limits are documented in [native-emulator-isolation.md](native-emulator-isolation.md). Hosted API-35 instrumentation and the separately recorded API-36 run pass. Native play on iOS/tvOS/webOS/Tizen is unavailable pending platform-specific containment; browser/stream routes keep their existing capability checks. |
| PLY-18 | Implemented; Dart regressions verified | Bounded recursive redaction of serialized Sentry events, nested maps/lists/keys; drop event on serialization/redaction failure. |
| PLY-19 | Implemented under owner repository policy | Automatic main-branch hosted security checks added. Main remains unprotected as explicitly accepted by the owner; protection is not pending remediation. Public PRs must use the owner-mandated isolated restricted-egress sandbox. |
| PLY-20 | Implemented; enforced resolution verified | Root CI dependency resolution now enforces pubspec.lock. |
| PLY-21 | Implemented; scheduled execution pending | Weekly Dependabot across Actions, Pub packages, Go, npm and Python requirements; scheduled Go vulnerability scan. Native vendored sources still require owner maintenance. |
| PLY-22 | Implemented; Python verified | Mock release qualification and assert the intended failure before dispatch; never invoke gh on a real run from this unit test. |
| PLY-23 | Guard added; translation work remains | Freeze the reviewed fallback ceiling at 1,242 keys / 44,712 locale entries. No machine-generated strings are represented as reviewed translations. |
| PLY-24 | Blocked on authentic release trust material | Keep remote catalog updates fail-closed. Do not invent production signing keys; pin only the actual owner-reviewed immutable active MilkRust root. The pinned revision `16490403726ba0240249b41903855583f4f9292d` was rechecked: `content/catalog-trust.json` still has `keys: {}` and `status: not-provisioned`. Current MilkRust main `dfcc50503d1a55b93d76c4e6c7376e0893d88af1` does not contain that trust file either. Provisioning authentic release custody is external to this app fix. |
| PLY-25 | Implemented; Python verified | Absolute deadlines for headers and small JSON request bodies, bounded worker slots, and forwarded-client headers accepted only from loopback reverse proxy. Drip-fed headers/bodies cannot renew the deadline. |
| PLY-26 | Implemented; hosted Linux containment verified | Final containment review reproduced same-user shared IPC access and `fchmodat2` file-mode changes through the old filter when compiled with older headers. Block semaphore operations, POSIX queues, extended-attribute reads and additional cross-process controls. Remove inherited capabilities; restrict descriptor commands and deny device controls, locks and filesystem watches, closing alternate signal-owner paths. Reject syscalls beyond the reviewed legacy ABI with `ENOSYS` so new kernel APIs cannot silently bypass the policy; libc retains its older thread-creation fallback. The regressions fail against the previous filters and pass with the fixes, verifying untouched parent-owned IPC and file fixtures and denied descriptor-owner changes without sending any signals. The final policy also passed the complete hosted Landlock/seccomp and production-build suite. |

## Qualification backlog

These acceptance items require the specified devices, test accounts, provider approvals or environments. They remain open until evidence is recorded; existing product features and experiments remain available under their established runtime controls.

- **Q01 — Full application qualification**: native/platform acceptance remains open. The prior integrated main commit `06908c891ba25de05e14e8e2b99a3173aa2ce665` passed full Flutter analysis, **9,897 Dart/widget tests with 22 skipped**, 789 focused regressions, and 563 repository checker tests with 9 skipped in [run 42664501317](https://github.com/snapetech-org/pleazyng/actions/runs/42664501317). This supersedes the earlier six Plex cloud-routing failures. The continuation adds native fault isolation and storage-migration checks; their candidate evidence is recorded below. Device and signed-package qualification remain separate.
- **Q02 — Profile/session race acceptance**: open. Exercise A→B→A profile transitions with delayed adapter loading, credential refresh, pending reader/media work and settings writes. Verify generation/owner guards using actual backends and platform stores; implemented guards are not evidence of completed device acceptance.
- **Q03 — Backup/restore durability**: open. Inject download cancellation, malformed imports, profile switches, storage failure and mid-import rollback. Preserve credentials and unrelated profiles; distinguish the PLY-10 network defect from otherwise implemented import ownership protections.
- **Q04 — Two-device sync and shared book identity**: open. Prove conflict convergence, deletion/tombstone compaction, stale-device rejoin, target failure isolation and encrypted recovery. Explicit shared item/library IDs are required for some cross-provider book matches; title similarity alone must not merge editions.
- **Q05 — Discovery and recommendation acceptance**: open. Qualify mixed-media decks, saved picks/voting, local taste controls, exact-ID adaptation matching, optional AI fallback and request privacy against actual providers. Measure target-device latency and verify that opt-out/local-only choices stay local.
- **Q06 — Publication and browser interoperability**: open. Run real EPUB/comic/PDF fixtures across Android WebView, Apple WebKit, Windows WebView2 and the Linux browser lifecycle, including malformed publications, navigation, selection and accessibility. Chromium-only checks cannot qualify every engine.
- **Q07 — Connected-source interoperability and scale**: open. Test the supported NAS/cloud providers, auth refresh, reconnect, cancellation and large directories on real systems. In particular qualify NFS RPC reuse/read-ahead, SFTP host-key changes and cloud OAuth behavior, and record latency/RAM/I/O budgets.
- **Q08 — Download and index recovery**: open. Exercise crash/resume, low disk, OS suspension, background transfer, lost source permissions and interrupted indexing. Confirm incomplete scans do not delete unvisited rows, while complete scans remove genuinely deleted entries.
- **Q09 — Purchase-entitlement acceptance**: open. Use store sandboxes for purchase/restore, replay, invalid or empty transaction history, refunds/revocation and offline operation. Source verification logic exists; this audit did not transact with Apple, Google, Microsoft or TV stores.
- **Q10 — Steam receiver and optional service acceptance**: open. Qualify native SDK app builds and real account/network/controller/decoder paths, deployed optional services, relay behavior and capture. The isolated H26x test is useful parser evidence, not an end-to-end Steam streaming qualification.
- **Q11 — RomM cores, saves and package signing**: open. Qualify each supported core/platform package, exact-copy matching, browser/native/stream routes, save restore compatibility, interrupts and storage lifetime. Desktop crash/hang, malformed-IPC and sandbox tests now have a dedicated hosted workflow. Actual core, signed-package and device acceptance remain open. Native play stays unavailable on platforms without an isolated worker; restoring those routes requires a supported containment implementation.
- **Q12 — Multiview platform and unfinished surface scope**: open. Detached video-window source is integrated on macOS, Windows and Linux. Native builds, concurrent decoder limits, audio/input ownership and device accessibility need acceptance. Non-video detached surfaces and application-crash playback restart remain explicitly open scope.
- **Q13 — Dolby Vision, FEL and acceleration experiments**: open. Retain the default-off/experimental boundaries until reference-output, HDR/DV signaling, seeking, synchronization and platform-specific evidence is captured. Ordinary builds should include implemented experiments per repository policy; packaging success is not image-quality proof.
- **Q14 — Visualizer runtime and formats**: open. Beyond the empty remote trust root, qualify actual helper/runtime packages, patched mpv capability detection, rendering fidelity, driver compatibility and lifecycle on each target. Unsupported .milk2 and link-only community sources must remain accurately labeled.
- **Q15 — Lending activation and provider boundaries**: open. OverDrive remains disabled by default pending approval, assigned credentials, deployed gateway controls and live authorization/circulation/fulfillment validation. Hoopla and other official handoffs are not equivalent native integrations. Do not remove gates merely because UI/source exists.
- **Q16 — Karaoke acceptance and remaining product scope**: open. Qualify companion jobs, cancellation/storage quotas, trusted HTTPS phone capture, microphone permissions and real device timing. Licensed catalog, hosted sharing, proprietary-format and live-monitor scope is documented as remaining work rather than supplied by the existing local workflow.
- **Q17 — LG and Samsung TV qualification**: open. Validate actual supported model/firmware combinations, native package install/signing, remote input, visible frames, HDR/audio passthrough and subtitle paths. LG embedded PGS/no-burn negotiations and older/broader model support remain constrained; Samsung physical-device acceptance is explicitly unqualified in the guide. Native packages do not constitute a full browser client or store approval.
- **Q18 — Accessibility and language quality**: open. Complete native-speaker review and device checks for large text, RTL, focus, remote/gamepad navigation, screen readers and reduced motion across new flows. Structural translation and widget checks do not establish usability on all supported targets.
- **Q19 — Deployment and supply-chain evidence**: open. Inspect actual TLS/proxy settings, trusted forwarding headers, secret management, logs/retention, quotas, backup/restore and production resource limits. Separately inventory built binaries, vendored/native advisories and historical secret exposure. Current-tree pattern checks, Go advisory checks and release-script review do not establish these external facts.
- **Q20 — Reconcile implementation and qualification records**: documentation reconciled; platform evidence remains open. The capability manifest now distinguishes implemented desktop video detachment from non-video detached surfaces and crash playback restart. The localization checker at integrated main `8c8728b6a684968264f9ad51ea5afd276edaa16b` records 5,212 messages across 37 locales, with the unchanged ceiling of 1,242 fallback keys and 44,712 fallback entries. Older F01–F17 entries remain historical; no device qualification is inferred from these edits.

## Latest integration and closure boundaries

The Android isolated service, universal isolation-ABI requirement, unavailable
host for unsupported platforms, worker/source packaging and Apple core-linkage
corrections are integrated into `main`. The Android test workflow now creates its
AVD in explicit runner-local directories and verifies emulator discovery before
compiling. Startup has an absolute deadline, detects an exited emulator and
preserves device logs and test APKs on failure. The workflow syntax correction is
commit [`b8b4ebd9412c29a25cbd512e4f5b1fb79202b6cf`](https://github.com/snapetech-org/pleazyng/commit/b8b4ebd9412c29a25cbd512e4f5b1fb79202b6cf).

- The integrated candidate `e0c08e674b1b25248be2ebc3f275e162d80c56a2` passed
  [hosted Dart analysis, focused regressions, formatting and repository checks](https://github.com/snapetech-org/pleazyng/actions/runs/42701734184/job/129449274454).
  Its Android job compiled all four test ABIs and passed lint, but failed to find
  the emulator before instrumentation started; that failure motivated the AVD
  workflow repair and is not counted as a runtime pass.
- Main revision `74e8d63d2c0ee757456d45c8aeed43e0bb74c905` passed the
  [Windows containment and production-build job](https://github.com/snapetech-org/pleazyng/actions/runs/42706066033/job/129463057202).
  Main revision `8c4d90647bbe30e46d022297ec7f6964fe87da9f` passed the
  [macOS containment and production-build job](https://github.com/snapetech-org/pleazyng/actions/runs/42706865641/job/129465848102).
- The separate [repository integration record](../maintainers/pr-consolidation-2026-11-09.md)
  reports a successful API-36 x86_64 emulator run on kspld0, Android lint and all
  four test ABIs. It also records a complete main-revision `74e8d63d2` Android
  debug app build with native exports, worker/core packaging, source receipts
  and 16 KiB alignment verified. These results are distinct from the hosted
  API-35 instrumentation run and from signed-release/device acceptance.
- [Run 42708996100](https://github.com/snapetech-org/pleazyng/actions/runs/42708996100)
  passed all four jobs at `a3d02611652485f1486c783a6143b99690d6b4a9`:
  Linux, Windows and macOS containment/production builds, and Android ABI
  compilation, lint and actual API-35 service instrumentation. This verifies the
  repaired emulator setup through completion, not merely AVD discovery.
- The final Linux policy at `07e9778d36028ffe6c99c7de72d0e74b0f6e4d83` passed
  [hosted Linux validation](https://github.com/snapetech-org/pleazyng/actions/runs/42710141311/job/129477197269):
  real worker/protocol faults, production compilation, all four CTest cases,
  25 packaging tests and Apple pod lock verification. The matching
  [Windows job](https://github.com/snapetech-org/pleazyng/actions/runs/42710141311/job/129477196985)
  also passed. This includes the descriptor-control and capability follow-up to
  the earlier shared-IPC/syscall fix.

Audit closure still requires reviewed translations (PLY-23), authentic MilkRust
release trust material (PLY-24), and the environments and evidence listed in
Q01–Q20. Native workers for iOS/tvOS/webOS/Tizen, non-video detached surfaces and
crash playback restart remain explicit implementation scope; unavailable or
unfinished features are not represented as shipped. Provider approvals,
production deployment, physical-device acceptance and signing custody cannot be
inferred from a source commit or a passing unit test.

## Executed validation

- PLY-26 follow-up: the syscall regression fails against the pre-fix production filter and passes with the fix, including an actual `fchmodat2` attempt against a private test file and same-user semaphore/message-queue fixtures. The production native targets rebuilt successfully; three local CTest cases (syscall policy, read-only input descriptors and unavailable-host core rejection), seven malformed-IPC cases and 25 RomM packaging tests passed. The local kernel still cannot supply Landlock; this result does not replace the hosted full-containment lane.
- Prior integrated main `06908c891ba25de05e14e8e2b99a3173aa2ce665`: [run 42664501317](https://github.com/snapetech-org/pleazyng/actions/runs/42664501317) passed every job, including full analysis, 9,897 Dart/widget tests (22 skipped), 789 focused regressions, 563 repository checker tests (9 skipped), canonical formatting and Go vulnerability scanning.
- Continuation: local seven-case malformed-protocol tests and 18 RomM packaging tests and 26 Tizen packaging tests passed. The migration candidate at `e1a609b21bdbf9167e1314194e400f0baf2514a4` passed full analysis, 836 focused Dart/widget tests and 563 repository checker tests (9 skipped) in [run 42686737474](https://github.com/snapetech-org/pleazyng/actions/runs/42686737474); its exact canonical-format patch was applied. The desktop candidate at `993c0f3b50e1b589a069fe49849769fb1ae049df` passed Linux and macOS sandbox fault tests and production compilation in [run 42687188056](https://github.com/snapetech-org/pleazyng/actions/runs/42687188056). The production libretro fixture integration also passed on Linux in [run 42688005316](https://github.com/snapetech-org/pleazyng/actions/runs/42688005316), and on Windows and macOS in [run 42688938069](https://github.com/snapetech-org/pleazyng/actions/runs/42688938069). The final stage-retirement candidate passed all three desktop jobs, including production builds and fixture-core integration, in [run 42689691356](https://github.com/snapetech-org/pleazyng/actions/runs/42689691356). That desktop candidate retained the older TV backend; the subsequent universal ABI guard and unavailable-host change remove that unsafe fallback. Source packages include the worker, transport and license notices. The local container reports Landlock `ENOSYS`; it was not treated as full sandbox validation.

- Go server and healthcheck: `go test -race ./...` passed; upstream coalescing, cancellation, failure cache and refill regressions included.
- Cloudflare Worker: 14 tests passed.
- Lending gateway: 12 tests passed, including idle headers, drip-fed headers/bodies and exhausted workers.
- Karaoke companion: 7 tests passed, including TLS admission and drip-fed headers; 3 optional-analysis tests skipped because those dependencies remain uninstalled locally.
- Workflow security/action-pin checks and locale structural/source checks passed. The clean hosted Python checker suite ran 572 tests: 563 passed and 9 skipped. This supersedes the local run whose two Dart-dependent checks could not execute. Hosted Go vulnerability scanning also passed.
- Final clean hosted Flutter 3.47.1 validation at `d5223619444d3d2f735056917a8869c23d0adfc2` ([run 42662289363](https://github.com/snapetech-org/pleazyng/actions/runs/42662289363)): enforced dependency lockfile, full analysis and **789 targeted Dart/widget/FFmpeg tests passed**, including every Plex service suite, credential isolation, cloud request teardown, PIN transitions and webOS authenticated-storage limits. Repository checker tests: **563 passed, 9 skipped**. The only failing step was canonical formatting of one new test; the exact uploaded formatter patch has been applied.
- The initial complete suite at `4190c6da769fb7f7f2ad50e3132ecfd95b4a9a1b` ([run 42656546231](https://github.com/snapetech-org/pleazyng/actions/runs/42656546231)) passed 9,881 tests with 22 skipped and exposed six legitimate Plex cloud calls blocked by the new origin guard. Fixed-origin cloud clients corrected all six, as confirmed by the final run above. Main, manual and scheduled security runs retain the complete application suite.
- After integration with concurrent main changes, release-related checker tests ran 122 cases: 121 passed and one skipped. Hosted Apple scratch changes were retained; shell syntax and workflow checks were revalidated after the final merge.
- Canonical formatter corrections from each hosted run were applied. The local SDK bootstrap was rejected by automatic approval review; it was not retried or bypassed.

Deployment changes are not live merely because source is committed. Apply the Worker and gateway/server changes through their existing deployment runbooks, preserving sessions, provider secrets, route bindings and rollback artifacts.
