# PlezyNG assessment remediation

Baseline: `d130a4e36ba7dfbac1a28bd8b719f472394de89e`.

This ledger records implementation and validation separately. Entries remain open
until their described behavior is implemented; a source change is not device or
release qualification. Changes are committed directly to `main` in small batches.

| Audit ID | Work | Implementation | Validation |
| --- | --- | --- | --- |
| D01, D11 | HLS gateway lifetime and long VOD manifests | Implemented: owner-scoped stable references, buffered-read grace, serialized rewrites; 50,000-reference manifest bound | Dart large-VOD, rolling-live, lifetime and rollback regressions pass; external-player/device duration qualification remains pending |
| D02-D03 | Recording stop and interrupted-file salvage | Implemented: finish in-flight resources; retain nonempty captures and recover journaled partials | Dart early-EOF, mid-segment deadline and interrupted recovery regressions pass; native player/device acceptance remains pending |
| D04-D05 | HLS rendition/map handling | Implemented as self-contained local HLS archives with separate audio, per-segment maps, AES-128 resources, discontinuities and programme timestamps; shared recording playback/deletion/recovery integrated | Dart archive/rendition/map/encryption/discontinuity regressions pass; native player/device execution remains pending |
| D06 | Bound credential payload caching; avoid caching encryption outputs | Implemented | Bulk import, entry/byte eviction and oversized-payload Dart regressions pass |
| D07 | Native P2P hash capability alignment | Implemented: SHA-256 multihash magnets and native v2 acceptance | Native v1, v2 and multi-file transfer, verified range/seek/EOF regressions compile and pass on Linux; platform/device qualification pending |
| D08 | External stream server reporting | Implemented: matched online items use their server reporting client with offline fallback | Dart reporting/session regressions pass; live provider/server acceptance remains pending |
| D09 | Progressive unified search | Implemented: independent source results, per-server title/people progress, generation/profile guarded publishing and usable results while remaining legs load | Partial publication, cancellation, filter retention and profile/race Dart regressions pass |
| D12 | Provider progress outbox rejects its own action kinds | Fixed: valid position/finished/restart/restore/cloud/podcast progress payloads are dispatched by their typed payload and checked against the outbox key | Source trace and Dart progress/outbox regressions complete; live provider acceptance remains pending |
| D13 | Three localization import paths point outside lib | Fixed subtitle-language settings, visualizer browser and subtitle AI sheet paths; added a directive-aware relative-import guard to CI | Three parser/resolution regressions pass; authored library paths checked against the exact main tree |
| D14 | Native visualizer worker contains displaced render-loop code in Status | Replaced the broken worker with the reconciled lifecycle/backend implementation while preserving UTF-8 path handling | Native worker, render-thread and isolated process regression binaries compile and pass |
| D15 | Missing HLS archive media is counted as a nonempty capture | Metadata-only archive masters now report zero retained media when the payload directory is missing or rejected; legacy direct captures retain byte counting | Missing-payload/direct-file and malformed-data Dart regressions pass |
| D16 | Every player uses instance ID zero | Restored a monotonically increasing instance token shared by PlayerBase implementations so Android stale-dispose guards can distinguish predecessor and successor cores | Distinct initialize and matching teardown tokens pass across player replacements in Flutter tests |
| D17 | Rejected HLS refreshes retain unpublished child capabilities and revive retired ones | Added address/count preflight and rollback of only newly allocated references; retired-reference adoption now commits only with a successful rewrite. Address validation no longer allocates unused HTTP clients | Capacity-exhaustion and failed-refresh retirement Dart regressions pass |
| D18 | One unreadable recording prevents all startup recovery and scheduler ticks | Recording recovery isolates filesystem/format errors per row, preserves files and journal paths, records a retryable recovery error, and continues other rows. Database failures still propagate | Unreadable-archive isolation and healthy-recording recovery Dart regressions pass |
| D19 | Database bootstrap marks recordings failed before the salvage worker can find them | Bootstrap now preserves interrupted/app_interrupted; the repository adopts only the exact legacy failed/interrupted combination and leaves ordinary failed captures alone | Production bootstrap SQL and Dart production-open/legacy-adoption regressions pass |
| D10 | Translation fallbacks and localized service status | Live-capture and file speech download/loading/transcription/translation/inference/CPU-fallback progress now carry typed phases/counts; UI resolves selected-locale messages and numbers at build time. All 37 status catalogs and generated accessors now cover the full 26-message namespace, with AI-authoring/review provenance. Other untranslated feature messages remain explicitly tracked | Locale/source/placeholder checks pass for 37 locales and 4,906 keys. All-locale generated capture/speech status resolution passes, including progress and number substitution. The wider backlog is 975 fallback keys / 35,100 locale entries; native-speaker and caption-specific device/large-text/RTL qualification remain pending |
| G01 | Native visualizer delivery | Reconciled PR #82 with ABI v2 MilkRust pin, native helpers, process/lifetime containment, platform runtime/source/notice builders, webOS SoLoud PCM and required bundle admission. Preserved current workflow policy; desktop/Android/Apple builders support local and compatible hosted/private workers | Five C++ regression binaries compile/pass; 3 receipt checks, 15 Tizen package checks and 8 webOS package checks pass. Linux Rust ABI v2 build, source/notice packaging and actual GL/GLES bundled-preset rendering pass on Mesa llvmpipe. Patched mpv artifacts, app/SDK packages and hardware/device qualification pending |
| G02 | Signed catalog activation | Publication/provisioning tooling retained; app continues to fail closed on its empty public root | Latest MilkRust PR #20 still records content/catalog-trust.json as not-provisioned with no keys. Production signing custody and reviewed public keys are unavailable; no keys or qualifications were fabricated |
| G03 | Live/DVR subtitle capture | Implemented: decoded-route capability gate; two-hour cue history; explicit DVR seeks preserve cues; unexplained live clock rollback clears the old epoch; same-channel server DVR reopen suspends/rebases capture; channel/audio changes invalidate it | Dart clock/seek/format regressions pass; native route, rollover and server-DVR device execution remain pending |
| G04 | P2P storage policy for large media | Implemented: per-profile 4/16/64/128/256 GiB choices, 64 GiB default, aggregate lease reservations, known-size checks and 512 MiB free-space reserve; native metadata checks the actual file requirement | Linux native metadata and verified reads across the 4 GiB boundary pass using a sparse fixture; Dart storage policy regressions pass. Physical low-space, mobile throughput and concurrent-device qualification remain pending |
| G05 | Dedicated karaoke implementation | Reconciled the previously unmerged PR #110 with current main: host/singer rotation, requests, lyrics/CD+G, rendition packages, practice, microphone/scoring/private takes, LAN room and opt-in preparation companion; fixed restored filler filtering and tempo-adjusted wait estimates | Companion protocol/recovery and Flutter format/CD+G/MIDI regressions pass. Native microphone/device execution, external licensed catalogs, hosted sharing, proprietary karaoke formats and live mic monitor buses remain open |
| G06 | RomM and emulator integration | Reconciled PR #111 source: profile-scoped authorization/catalog, exact-copy routes, embedded browser/stream/native host, isolated player proxy, durable save journals/conflicts, offline download recovery and core build recipes | Dart URL/copy/auth/capability regressions and Linux host/core build/loading pass. Normal package recipes include the three default cores and source. Full app packages, Apple signing and server/device execution remain pending |
| G07 | Full theme packages | Implemented v1 native package schema with color, geometry, typography and adaptive/sidebar/bottom flow; bounded import/export, preview, persistence, reset and corrupt-package fallback; TV/automotive retain their navigation contracts | Dart schema, geometry, typography, import/export and navigation regressions pass. All-locale/RTL widget checks pass; physical TV/native focus and full theme device qualification remain pending |
| G08 | Remaining podcast functions | Per-show automatic downloads/retention, restart-safe discovery and opt-in alerts implemented; manual downloads protected; foreground worker integrated with profile/lifecycle/download owners. Archive pagination and transcript search/seek with encrypted offline caching added; opt-in gpodder API v2 sync integrated with HTTPS configuration, unique device IDs, independent revision acknowledgments, deferred active-session changes and explicit progress conflicts. Known-duration RSS episodes supported; HTTP imports remain queued for manual setup | Dart policy, private archive identity/restart, transcript, gpodder protocol and acknowledgment regressions pass; native worker/server/device execution remains pending |
| G09 | Remaining Steam transport/presentation scope | Reconciled PR #81/#111 source: desktop/Apple receivers, HDR/surround, cloud/family actions, internet tunnel/relay, controller mapping/feedback/motion, touch editor, microphone ownership, SDK preparation and package inspection. Kept current Opus patches and Android direct-egress setup while adding Granite patches and SDK layout recovery | Games Flutter tests, 37 SDK recipe tests and 15 Android SDK setup tests pass; companion checks pass with recorded socket skips. Native SDK packages, live account/network/device acceptance and optional-service deployment remain pending |
| G10 | Detached desktop Multiview windows and recovery | Native macOS/AppKit, Windows and Linux/Wayland hosts move the retained video/OSD surface without reopening media or duplicating progress/auth/decoder owners. Workspace and source-video controls route through their original owners; close returns to the pane, stale controls are revoked, queued intents are bounded. Profile/slot geometry is persisted using native facilities; Wayland restores size under compositor placement. Desktop non-video surfaces use additional Flutter views where supported. Profile-local checkpoints preserve safe identities and positions; after restart, the session tray offers explicit reauthorization and resume through the active profile. Games never auto-launch, and media is not auto-started on process recovery. | Dart owner/token/geometry/queued-close/route-restore/recovery regressions pass. All three native host builds/device tests remain pending; see [Multiview delivery](../plezyng/multiview/DELIVERY.md). |
| M01 | Current release/capability documentation and guards | README and ledger distinguish historical v3.0.0 publication from current API unavailability; current integrated product boundaries corrected; independent metadata and availability checks added | Current list/latest/tag/release-ID API responses captured on November 6; historical November 5 publication evidence retained. Capability/release-availability guards and their regressions pass |
| M02 | Required public platform delivery | Future versioned releases reject omitted webOS/Tizen/Windows ARM64 and verify the assembled platform artifacts before creating a release. Existing eligibility gates retained | Coverage regressions pass. Current public-release unavailability and the historical webOS omission require eligible artifacts and release publication; no workflow-dispatch or release-upload capability is exposed here |
| M03 | Remove tracked generated package outputs | Removed 16 files / 94,520,572 bytes of generated shared_preferences package output; nested package build directories ignored and source-tree guard added | Current tree checked; history intentionally preserved |

## Delivery checkpoint

### Follow-up integration checks

The complete Flutter run at the synchronized pre-follow-up Dart tree finished
with **9,505 passes, 15 explicit skips and 16 failures** in 27m41s. All 16 failure
causes were repaired: stale Simkl/Trakt identity expectations, broker/relay
fixtures that depended on absent build configuration, and the retired Android
upstream trust domain. The affected suites plus captions/locales and newer
main download/Plex/widget changes pass **483 focused cases across the reruns**.
One newly written matcher initially used too many positional arguments; its
23-case file passes after using the iterable form. This is a completed broad
run plus targeted verification, not a claim that a second full run was green.
Full `lib`/`test` analysis reports **zero errors and zero warnings**; 186 style
information messages remain. After preserving main’s newer `1ceb0db` visual changes,
all **136 appearance/theme cases**, including visual baselines and responsive
geometry, pass. The final analyzer at the combined caption/visual tree again
reports zero errors and zero warnings. These checks are recorded after
`bd782e8`; platform binaries and device qualification remain separate. The Go suites, native torrent tests, Linux RomM
host/cores and MilkRust GL/GLES render checks also pass as recorded below.

Build-configured relay/store/availability hosts retain system-only certificate
trust, while user-entered media servers retain owner-installed CA support.
Storefront requests validate injected broker endpoints and reject empty-host
HTTPS links. The Android and Dart fixed-provider lists no longer contain the
retired upstream service domain. Real TLS and routing regressions pass.

Caption-status coverage is now complete across all 37 supported locales:
**884 previously empty locale entries** were replaced for the 26-message
namespace. Placeholders, generated accessors and every runtime status phase
pass checks. The 110 stale English source hashes were independently reproduced
using only the app-name substitution before recording the new checkpoint.
There are still **975 other fallback keys / 35,100 locale entries**. The rejected
bulk machine drafts were not merged; no native-speaker approval is claimed.

On November 6, the current GitHub release list exposed only the old `2.24.1`
draft. The latest endpoint, `v3.0.0` tag endpoint and recorded release ID all
returned 404. Current availability evidence is saved separately; the November 5
publication record remains intact. The cause is unknown. The manifest and README
no longer present that historical record as proof of a current public download.
Five release-metadata/availability regressions and eight locale-validator tests
pass. No release or asset was published by this remediation session.

The native torrent engine now passes real v1/v2 and multi-file transfers,
metadata, verified byte ranges, reverse seeks and EOF under libtorrent 2.0.11.
The v2 regression fixture had placed its seed under a directory absent from its
single-file v2 metadata; it now writes the advertised path and prints useful
failure diagnostics. The additional sparse 4 GiB + 271-byte fixture now verifies the exact size, reads beyond the 32-bit boundary, a boundary-crossing read, backward seeks and EOF without allocating a full media buffer. Mobile throughput remains unqualified.

MilkRust's previous source pin could not build with `--locked`. The new exact
pin `16490403726ba0240249b41903855583f4f9292d` carries its dependency-lock and
native compiler repairs. The isolated build disables rustup self-update so it
does not look for a launcher inside its temporary Cargo home. The full Linux
builder now produces the ABI v2 library, source archive, notices and receipt.
Both bundled presets render 12 distinct nonblank frames from real PCM through
desktop OpenGL and GLES on Mesa llvmpipe. The reusable smoke script also rejects
identical output across different presets and terminates a driver hang after
30 seconds. This establishes software rendering, not hardware qualification.

Two supplementary MilkRust source-test files report 10 passes and three failed
assertions: `resource_limits` still expects shape index 63 to be accepted where
the runtime now enforces MilkDrop 3's four-shape contract; `shader_translation`
expects an older texture-call spelling and the formerly missing WGSL remainder
path. Those upstream fixtures remain unresolved; no all-green MilkRust suite or
pixel-reference parity is claimed.


Search cancellation now preserves the prior visible result set, while selected
kind/People filters remain active until all sources finish. Optional Steam
relay configuration no longer throws while settings render. Diagnostic and
OAuth clients accept a validated per-instance endpoint so tests exercise the
same request construction without depending on compiled deployment secrets.
Targeted search/log/podcast checks pass; the follow-up migration, Games, callback
and theme batch passes 54 cases with seven explicit platform/environment skips.
That earlier broad Flutter run has now completed; the final results are recorded above. The 96-case sequential rerun across
search, startup recovery, dialogs, Discover and NFS setup passes. The optional
Go server and healthcheck packages also pass their complete test suites under
Go 1.27.3. The broad run exposed a newly introduced
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
this ledger and that the listed executed checks passed. Confidence in the executed Flutter paths is high. Confidence in unbuilt native
platform integrations remains moderate; device performance, compatibility and
installation results at this revision are unknown.

Executed checks include the relative Dart directive guard and its three parser
regressions, 41 Python checks for workflows/imports/release coverage, locale and
capability-manifest guards, five compiled C++ visualizer regression binaries,
Games SDK/setup and companion checks, and Tizen/webOS package-recipe tests.
The production recording-bootstrap UPDATE was extracted and executed against
SQLite to verify its interrupted/app_interrupted state contract. Recipe/fixture
checks do not establish that an actual application package was built.

Flutter 3.47.1 / Dart 3.13.1, Go 1.27.3, Rust 1.97.0, CMake and a local Clang
compiler are available at this checkpoint. Apple/Android/TV SDKs and the Linux
application development dependencies are not installed here. The connected
GitHub tools expose neither workflow dispatch nor release-asset upload;
existing CI/release workflows remain opt-in. No workflow trigger was changed
to bypass that boundary, and no full application package or device qualification
is claimed.

Remaining source/product scope includes the explicit translation backlog,
karaoke licensed catalog/hosted-sharing/proprietary-format/live-monitor scope,
and platform emulator-core package/signing qualification. Multiview now has
profile-local checkpoint recovery with explicit user resume; automatic media
startup after a crash is deliberately not part of that contract. Production catalog root provisioning
requires reviewed public keys and real signing custody. The current public-release availability gap and historical v3.0.0 webOS
omission require eligible artifacts and release publication. The
per-feature acceptance column remains authoritative; this checkpoint does not
mark the entire requested project scope complete.
