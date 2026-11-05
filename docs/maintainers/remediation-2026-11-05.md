# PlezyNG assessment remediation

Baseline: `d130a4e36ba7dfbac1a28bd8b719f472394de89e`.

This ledger records implementation and validation separately. Entries remain open
until their described behavior is implemented; a source change is not device or
release qualification. Changes are committed directly to `main` in small batches.

| Audit ID | Work | Implementation | Validation |
| --- | --- | --- | --- |
| D01, D11 | HLS gateway lifetime and long VOD manifests | Implemented: owner-scoped stable references, buffered-read grace, serialized rewrites; 50,000-reference manifest bound | Large VOD and rolling live regression cases added; execution pending |
| D02-D03 | Recording stop and interrupted-file salvage | Implemented: finish in-flight resources; retain nonempty captures and recover journaled partials | Early EOF and mid-segment deadline regression cases added; execution pending |
| D04-D05 | HLS rendition/map handling | Implemented as self-contained local HLS archives with separate audio, per-segment maps, AES-128 resources, discontinuities and programme timestamps; shared recording playback/deletion/recovery integrated | Archive regression cases added; native player/device execution pending |
| D06 | Bound credential payload caching; avoid caching encryption outputs | Implemented | Regression cases added; execution pending |
| D07 | Native P2P hash capability alignment | Implemented: SHA-256 multihash magnets and native v2 acceptance | Native v2 transfer regression added; execution pending |
| D08 | External stream server reporting | Implemented: matched online items use their server reporting client with offline fallback | Provider/server session acceptance pending |
| D09 | Progressive unified search | Implemented: independent source results, per-server title/people progress, generation/profile guarded publishing and usable results while remaining legs load | Partial publication and A/B/A race regressions added; execution pending |
| D12 | Provider progress outbox rejects its own action kinds | Fixed: valid position/finished/restart/restore/cloud/podcast progress payloads are dispatched by their typed payload and checked against the outbox key | Source trace completed; provider acceptance pending |
| D13 | Three localization import paths point outside lib | Fixed subtitle-language settings, visualizer browser and subtitle AI sheet paths; added a directive-aware relative-import guard to CI | Three parser/resolution regressions pass; authored library paths checked against the exact main tree |
| D14 | Native visualizer worker contains displaced render-loop code in Status | Replaced the broken worker with the reconciled lifecycle/backend implementation while preserving UTF-8 path handling | Native worker, render-thread and isolated process regression binaries compile and pass |
| D15 | Missing HLS archive media is counted as a nonempty capture | Metadata-only archive masters now report zero retained media when the payload directory is missing or rejected; legacy direct captures retain byte counting | Missing-payload/direct-file regression case added; execution pending |
| D16 | Every player uses instance ID zero | Restored a monotonically increasing instance token shared by PlayerBase implementations so Android stale-dispose guards can distinguish predecessor and successor cores | Regression asserts distinct initialize tokens and matching teardown tokens across three replacements; Flutter execution pending |
| D17 | Rejected HLS refreshes retain unpublished child capabilities and revive retired ones | Added address/count preflight and rollback of only newly allocated references; retired-reference adoption now commits only with a successful rewrite. Address validation no longer allocates unused HTTP clients | Capacity-exhaustion and failed-refresh retirement regressions added; Flutter execution pending |
| D18 | One unreadable recording prevents all startup recovery and scheduler ticks | Recording recovery isolates filesystem/format errors per row, preserves files and journal paths, records a retryable recovery error, and continues other rows. Database failures still propagate | Unreadable-archive plus healthy-recording regression added; Flutter execution pending |
| D19 | Database bootstrap marks recordings failed before the salvage worker can find them | Bootstrap now preserves interrupted/app_interrupted; the repository adopts only the exact legacy failed/interrupted combination and leaves ordinary failed captures alone | Actual production SQL executed against SQLite and preserves the required state. Production-open and legacy-adoption Dart regressions added; Flutter execution pending |
| D10 | Translation fallbacks and localized service status | Live-capture and file speech download/loading/transcription/translation/inference/CPU-fallback progress now carry typed phases/counts; UI resolves selected-locale messages and numbers at build time. English/Arabic/German status catalogs and generated accessors added, with machine-authored provenance. Other untranslated feature messages remain explicitly tracked | Locale/source/placeholder checks pass. Typed status/language-resolution cases added; Flutter execution, remaining translations and native-speaker/large-text/RTL qualification pending |
| G01 | Native visualizer delivery | Reconciled PR #82 with ABI v2 MilkRust pin, native helpers, process/lifetime containment, platform runtime/source/notice builders, webOS SoLoud PCM and required bundle admission. Preserved current workflow policy; desktop/Android/Apple builders support local and compatible hosted/private workers | Five C++ regression binaries compile/pass; 3 receipt checks, 15 Tizen package checks and 8 webOS package checks pass. Actual Rust runtime, patched mpv artifacts, app/SDK packages and GPU/device qualification pending |
| G02 | Signed catalog activation | Publication/provisioning tooling retained; app continues to fail closed on its empty public root | Latest MilkRust PR #20 still records content/catalog-trust.json as not-provisioned with no keys. Production signing custody and reviewed public keys are unavailable; no keys or qualifications were fabricated |
| G03 | Live/DVR subtitle capture | Implemented: decoded-route capability gate; two-hour cue history; explicit DVR seeks preserve cues; unexplained live clock rollback clears the old epoch; same-channel server DVR reopen suspends/rebases capture; channel/audio changes invalidate it | Clock/seek/format regression cases added; native route, rollover and server-DVR device execution pending |
| G04 | P2P storage policy for large media | Implemented: per-profile 4/16/64/128/256 GiB choices, 64 GiB default, aggregate lease reservations, known-size checks and 512 MiB free-space reserve; native metadata checks the actual file requirement | Native transfer/large-file, low-space and concurrent-device execution pending |
| G05 | Dedicated karaoke implementation | Reconciled the previously unmerged PR #110 with current main: host/singer rotation, requests, lyrics/CD+G, rendition packages, practice, microphone/scoring/private takes, LAN room and opt-in preparation companion; fixed restored filler filtering and tempo-adjusted wait estimates | Companion protocol/recovery tests pass; format/CD+G/MIDI regression cases added. Flutter/native execution and external licensed catalogs, hosted sharing, proprietary karaoke formats and live mic monitor buses remain open |
| G06 | RomM and emulator integration | Reconciled PR #111 source: profile-scoped authorization/catalog, exact-copy routes, embedded browser/stream/native host, isolated player proxy, durable save journals/conflicts, offline download recovery and core build recipes | URL/copy/capability regression cases added. Linux native host/core build and loading pass; normal platform build/packaging now includes the three default cores and corresponding source. Full app packages, Apple signing and server/device execution remain pending |
| G07 | Full theme packages | Implemented v1 native package schema with color, geometry, typography and adaptive/sidebar/bottom flow; bounded import/export, preview, persistence, reset and corrupt-package fallback; TV/automotive retain their navigation contracts | Schema/round-trip cases added; RTL, 200% text, native focus and migration execution pending |
| G08 | Remaining podcast functions | Per-show automatic downloads/retention, restart-safe discovery and opt-in alerts implemented; manual downloads protected; foreground worker integrated with profile/lifecycle/download owners. Archive pagination and transcript search/seek with encrypted offline caching added; opt-in gpodder API v2 sync integrated with HTTPS configuration, unique device IDs, independent revision acknowledgments, deferred active-session changes and explicit progress conflicts. Known-duration RSS episodes supported; HTTP imports remain queued for manual setup | Policy, private archive restart/identity and transcript regression cases added; gpodder protocol and acknowledgment regressions added; worker/native/server/device execution pending |
| G09 | Remaining Steam transport/presentation scope | Reconciled PR #81/#111 source: desktop/Apple receivers, HDR/surround, cloud/family actions, internet tunnel/relay, controller mapping/feedback/motion, touch editor, microphone ownership, SDK preparation and package inspection. Kept current Opus patches and Android direct-egress setup while adding Granite patches and SDK layout recovery | 37 Games SDK tests and 15 Android SDK setup tests pass; cloud companion 10 pass/6 socket skips. Flutter, native SDK builds, account/network/device acceptance and deployed optional services pending |
| G10 | Detached desktop Multiview windows | Native macOS/AppKit, Windows and Linux/Wayland hosts move the retained video/OSD surface without reopening media or duplicating progress/auth/decoder owners. Workspace and source-video controls route through their original owners; close returns to the pane, stale controls are revoked, queued intents are bounded. Profile/slot geometry is persisted using native facilities; Wayland restores size under compositor placement. Removed the unused child-process RPC experiment | Owner/token/geometry/queued-close/route-restore regression cases added; Flutter and all three native SDK builds/device tests pending. Games/readers/music retain their existing in-app surfaces; application-crash playback restart and non-video detached surfaces are not claimed |
| M01 | Current release/capability documentation and guards | README and ledger describe the published v3.0.0 release using captured GitHub metadata; current integrated product boundaries corrected; optional independent release-metadata check added | Published tag, source commit, date and actual asset names read from GitHub; capability-manifest and workflow architecture checks pass |
| M02 | Required public platform delivery | Future versioned releases reject omitted webOS/Tizen/Windows ARM64 and verify the assembled platform artifacts before creating a release. Existing eligibility gates retained | Coverage regressions pass. v3.0.0 public webOS repair still requires an eligible packaged artifact and release upload; no matching write capability is exposed in this session |
| M03 | Remove tracked generated package outputs | Removed 16 files / 94,520,572 bytes of generated shared_preferences package output; nested package build directories ignored and source-tree guard added | Current tree checked; history intentionally preserved |

## Delivery checkpoint

### Follow-up integration checks

Search cancellation now preserves the prior visible result set, while selected
kind/People filters remain active until all sources finish. Optional Steam
relay configuration no longer throws while settings render. Diagnostic and
OAuth clients accept a validated per-instance endpoint so tests exercise the
same request construction without depending on compiled deployment secrets.
Targeted search/log/podcast checks pass; the follow-up migration, Games, callback
and theme batch passes 54 cases with seven explicit platform/environment skips.
The broad Flutter run is still in progress. It exposed a newly introduced
focus-button assumption that scoped Material themes always contain MonoTokens;
the synchronized main control now supplies a fallback when that extension is absent.


Normal RomM packaging now builds Gambatte, mGBA and FCEUmm from one canonical
pin file across app toolchains. Linux builds and dynamic loading pass for the
host and all three cores. Fixed desktop install ordering, added Android ABI/
export/dependency/source checks, Apple atomic four-framework delivery and cache
validation, and TV core/source staging. Nineteen package checks and nineteen
Tizen recipe tests pass. The package includes exact core source archives plus
host headers, notices and build recipe; no platform/device qualification is
inferred from those checks.

Flutter 3.47.1 dependencies now resolve on this host. Full analysis of `lib` and
`test` found 22 compile errors in the integrated karaoke, caption and detached
window paths. Updated the file-picker and TV APIs, nullable media title handling
and optional-interface casts; regenerated desktop microphone plugin registration.
The follow-up analyzer reports zero errors and zero warnings (style lints remain).
Flutter regression execution exposed and repaired four failures: nullable theme
font metrics, pre-normalization RomM path traversal, WebVTT terminator retention
and malformed recording data being classified as an I/O error. The 56 focused
cases across credentials, recording/archive recovery, visualizers, RomM, karaoke,
themes and podcast policy/archive/sync now pass across the focused reruns. Linux
CJK font fallbacks remain covered. The 327 Python check cases pass across the
full run and the two compiler-dependent icon-check reruns.

The Dart parser exposed three authored-source blockers: the Games screen had
been truncated at 24,000 bytes, the visualizer content validator contained a
duplicated function body inside an unterminated regular expression, and RomM's
save-key expression was ambiguous. Restored the missing Games actions from the
complete PR #111 blob (`2efe2096ece75bb9ca79c2bd0cf29c492d92a005`), verified the
blob hash and preserved the current prefix. Repaired both expressions and kept
the image-budget checks. The production visualizer validator passes standalone
Dart checks for engine-profile markers, shader includes and truncated PNGs;
its targeted analyzer reports no diagnostics. The Linux RomM native host also
compiles and links with the pinned libretro/miniaudio sources on this host.

The full Python check suite exposed an undeclared RomM WebKit runtime in Linux
package metadata and stale recovery tests that still expected webOS omission.
Debian, RPM, Arch, PPA and Snap metadata now includes the browser runtime, and
recovery regressions require both the webOS build and its public artifact.
The 42 focused dependency/recovery/coverage checks pass. The five compiled C++
visualizer regression binaries also pass. Flutter SDK setup is now possible in
the current host; the earlier tool-availability statement below is historical.

Confidence is high that the published commits contain the changes recorded in
this ledger and that the listed executed checks passed. Confidence in the
uncompiled Flutter/native integrations is moderate; device performance,
compatibility and installation results at this revision are unknown.

Executed checks include the relative Dart directive guard and its three parser
regressions, 41 Python checks for workflows/imports/release coverage, locale and
capability-manifest guards, five compiled C++ visualizer regression binaries,
Games SDK/setup and companion checks, and Tizen/webOS package-recipe tests.
The production recording-bootstrap UPDATE was extracted and executed against
SQLite to verify its interrupted/app_interrupted state contract. Recipe/fixture
checks do not establish that an actual application package was built.

Flutter/Dart, Go, CMake and platform SDKs are absent in this environment. The
connected GitHub tools support source commits but expose neither workflow
dispatch nor release-asset upload; existing CI/release workflows are opt-in. No
workflow trigger was changed to bypass that boundary, and no full application
build or device qualification is claimed.

Remaining source/product scope includes the explicit translation backlog,
non-video detached surfaces and application-crash playback restart, karaoke
licensed catalog/hosted-sharing/proprietary-format/live-monitor scope, and
packaged signed emulator-core delivery. Production catalog root provisioning
requires reviewed public keys and real signing custody. The existing v3.0.0
webOS delivery gap requires an eligible artifact and release attachment. The
per-feature acceptance column remains authoritative; this checkpoint does not
mark the entire requested project scope complete.
