# PR consolidation and security resolution — 2026-11-09

All 25 PRs open at the start were reviewed: 20 merged and five closed with
specific dispositions. GitHub has no open PRs and only the default `main`
branch. Every merged PR tip is retained as an ancestor of main; published
history was not rewritten. The [machine-readable receipt](pr-consolidation-2026-11-09.json)
records authors, reviewed heads, outcomes and branch snapshots. Existing local
branches attached to other worktrees were preserved.

| PRs | Outcome |
| --- | --- |
| #278, #279, #281, #282 | Merged Decky UI/TypeScript/types/tslib updates; replaced the legacy Rollup build dependency chain with esbuild. |
| #269–#272 | Merged official release-tag-verified immutable Action pins and updated the JNI workflow guard. |
| #283–#285, #287–#291 | Merged compatible plugin/lint dependencies and verified the solved wake-lock graph. |
| #274, #276, #277 | Merged Quantizer/Demucs/Librosa updates; kept Python 3.11 analysis compatibility. |
| #293 | Merged music discovery, durable queues and car adapters with its explicit incomplete-parity/native-qualification ledger. |
| #268 | Closed: identical checkout SHA already on main. |
| #273 | Closed: proposed NumPy floor excludes the exporter's pinned Python 3.11 wheel. |
| #275 | Closed: isolated 2.4 compiler bump breaks the coordinated LiteRT 2.3 qualification cohort. |
| #280 | Closed: Rollup was superseded by the tested esbuild replacement. |
| #286 | Closed: native Pigeon/provenance contract requires a complete coordinated refresh. |

The remaining audit-remediation branch commits were integrated, including
Android isolated-UID containment, worker packaging checks, correct Apple pod
locks and removal of unsafe native-core fallback. Native RomM emulation is
unavailable on iOS/tvOS/webOS/Tizen until an OS-isolated helper exists there;
capability-checked browser and streaming routes remain. This is recorded in the
[security ledger](../security/audit-remediation-2026-11-09.md).

The mutable appcast branch writer is retired. An immutable annotated `appcast`
tag preserves the legacy feed at its reviewed commit. Its v3.0.7 payload migrates
clients to release-asset feeds. The legacy raw URL was verified after branch
deletion. No release or existing tag was rewritten.

## Security evidence

GitHub reports zero open Dependabot, code-scanning and secret-scanning alerts.
Dependabot #57 is **fixed**, not dismissed: the vulnerable transitive deepmerge
chain was removed entirely. Decky and reader-tool npm audits report zero
vulnerabilities; a fresh Go vulnerability scan reports none. CodeQL execution
remains disabled under the owner's directive. Zero alert counts do not close
external deployment, device, signing-root or provider qualification items in the
security ledger.

## Verification

- Decky: typecheck, production build, eight JS/build-loader tests, 16 Python
  bridge tests, packaged ZIP and zero-vulnerability audit.
- Actions: official tag/SHA checks, security/pin/build guards; final checker
  suite **581 tests, 572 passed and nine skipped**.
- Plugins: all affected package graphs resolve; wake-lock analysis and Linux/web
  lifecycle tests pass; runtime-input provenance passes.
- ML: ten companion tests including real synthetic CPU separation/checkpoint
  rejection; Librosa 1.0 tempo/chord and isolated-vocal pitch checks; motion
  exporter tests. Qualified CPU/Python/platform limits remain documented.
- Music integration: **285 tests passed**, full analysis, canonical maintained
  formatting, strict localization/translation checks and isolated codegen check.
- Containment: Linux real worker/protocol faults and all three production CTest
  cases pass; 25 packaging tests, three Dart boundary tests and Apple checksum
  locks pass. All four Android test ABIs compile; API-36 x86_64 headless emulator
  passes production service file/network denial, firmware VFS, frames/save,
  crash/hang/oversized-state/stuck-close/suspension/restart tests and lint.

Hosted security and native-platform validation remain queued/running independently;
no active build was cancelled to consolidate branches. Physical automotive,
Apple signing and other device acceptance retain their explicit open status.

## Additional full Android application build

A fresh task-owned checkout bypassed the stale canonical shared Moonlight cache
without modifying it. Full app Kotlin compilation passed; after fast-forwarding
the checkout to current main `74e8d63d2`, the complete 3.0.19 debug APK assembled.
Its actual Flutter application ABI set is arm64-v8a, armeabi-v7a and x86_64
(the separate containment test target also compiles x86). Final package checks
verify Steam JNI exports, parent/worker/core libraries and exports, corresponding
source receipts, dependency packaging and 16 KiB ZIP alignment. The verified
APK and machine-readable checker report are retained with the local QA evidence.
This is a debug build/package result, not a signed release or physical-car claim.

The independent hosted [Decky validation](https://github.com/snapetech-org/pleazyng/actions/runs/42705515200)
passed on Ubuntu 24.04 at revision `aa17d7fea` (npm install/audit, typecheck,
production build, JS/bridge tests and packaging).
Existing full security/native runs were preserved. The concurrent Apple resolver
change on main also passed its three focused Python tests.
