# Games validation and release gates

## SDK preparation and real Android compilation — 2026-10-29

[SDK_BUILD_HANDOFF.md](SDK_BUILD_HANDOFF.md) contains the committed platform
preparation, build commands and agent acceptance criteria. These checks extend
the earlier source checkpoints below; no full Apple/Windows build or hardware
result is inferred from them.

- Official Android command-line tools **22.0 / 15859902** were downloaded and
  checked against Google's published SHA-256. JDK **21.0.12**, build tools
  **36.1.0**, NDK **29.0.14206865**, CMake **3.22.1/4.1.2** and platform APIs
  **34, 35, 36, 37.0** were installed and verified. Vendored plugins' older SDK
  declarations are included. Real installation exposed malformed nested legacy
  platform directories; the guarded repair and serial installer were exercised.
- The actual Steam JNI runtime, crypto/transport, Opus, Granite and direct
  Vulkan/Pyrowave path compile and link in Release for **arm64-v8a,
  armeabi-v7a, x86 and x86_64** with the pinned NDK/CMake and requested native
  API 25. Each artifact exports all **42** required JNI entry points, has the
  correct ELF machine, and has no text relocations or runtime search paths.
  ARM64 and x86_64 LOAD segments meet **16 KB** alignment; 32-bit targets retain
  compatible 4 KB alignment. These are standalone JNI builds, not APK/AAB builds.
- The vendored controller's Java and all Kotlin sources compile against its
  declared **API 34** and the real Flutter **3.47.1** embedding. The actual
  `SteamStreamPlatformViewFactory.kt` compiles against **API 37.0**. Kotlin
  **2.4.10** and JDK 21 were used. The two compatibility vibrator deprecations
  remain; Kotlin compilation produced no diagnostics. Gradle dependency
  resolution, app resources, R8, signing and package execution are still gates.
- Linux SDK preflight passes with GTK **3.24.41**, libsecret **0.21.4**, libevdev
  **1.13.1**, Wayland **1.22.0**, EGL **1.5**, GStreamer **1.24.2**, Vulkan
  **1.3.275** and CMake **3.28.3**. Real GStreamer inspection finds all required
  elements, including H.264/H.265 decoding/parsing, capture/playback endpoints
  and the OpenH264 test encoder. This does not access a microphone or qualify
  a display/GPU.
- The official VS 2022 bootstrapper was downloaded and SHA-256 verified. The
  Windows script parses under PowerShell **7.4.19**, and its non-Windows refusal
  executes correctly. Microsoft Windows SDK **10.0.26100.9457** package contents
  were inspected to confirm receiver import-library names. Actual installation,
  Windows Authenticode verification, MSVC compilation and execution have not run.
- **39 Python tests pass**: 14 shared Android SDK tests and 25 Games preparation,
  archive and artifact checks. Cases include checksum/traversal/link rejection,
  platform layout identity, partial installs, preserved Apple archives, wrong
  Xcode selection, bundled/downloaded Metal, failed-receipt invalidation, actual
  shader extraction, ABI/JNI/alignment rejection and missing Linux codecs.
- Workflow action-pin, architecture/private-runner and security checks pass.
  The existing private jobs now invoke SDK preflight/probes and preserve receipts;
  Linux image dependencies cover the codec and shader tools. Runner routing,
  trust, manual dispatch and hosted-fallback policy are unchanged. No workflow
  was dispatched and no runner image/service was deployed by this preparation.
- After integrating current main, the native build and CTest run pass again:
  **42 passed, one display-dependent test skipped**. Android Intel targets
  reconfigure/build/inspect successfully with unchanged binaries. The six Mac
  Flutter-cache regression tests also pass. Incoming iOS simulator settings had
  six unquoted conditional keys: their OpenStep parse failure was reproduced,
  the keys were quoted, and all three Apple project files parse successfully.
  Apple SDK preflight now invokes native `plutil -lint` before source probes.

Standalone JNI artifact SHA-256 values (unstripped development outputs, not
release-distribution checksums):

| ABI | SHA-256 |
| --- | --- |
| arm64-v8a | `b520538c076840080e2e70b4a3cf06f067344b263f667e5ca16c75de87377c8d` |
| armeabi-v7a | `b32accda046b515a47136368c36704a5958714ec712c0dee03174e610c17431d` |
| x86 | `0ade78329a4323bc02b356e843c209eaf670de9eaa0aee9d311b9e363a5dc01b` |
| x86_64 | `1a9d112634169174ed2d95e7145d1287f4a5b7274476e01fca22220aefd8c03f` |

Application/native feature logic is unchanged from the preceding ownership
checkpoint. The latest-main integration also preserves Darwin interface-flag
visibility, parent CTest isolation from Opus, private-JIT memory/disk fixes and
Apple simulator project changes. Historical Flutter, native runtime and Go
results below still identify their original checks.
Apple's real Xcode SDKs must be provisioned on Mac agents; unit-tested command
construction is not Apple compilation. Full Gradle packages, MSVC, Xcode,
hardware, live accounts and service deployment remain the handoff gates.

## Earlier source checkpoints

Current source checkpoint is [PR #81](https://github.com/snapetech-org/PlezyNG/pull/81):
[Vulkan/HDR10](VULKAN_RECEIVER.md), [Cloud files](STEAM_CLOUD.md) and
[paired internet streaming](STEAM_INTERNET.md), [Windows/Apple HDR](DESKTOP_HDR.md)
and [Families management](STEAM_FAMILIES.md). Its checkpoint sections
at the end record local evidence. Older platform milestones below are historical;
they do not establish hardware HDR, current SDK builds or deployed service support.

For current completion status, see
[CONNECTED_EXPERIENCE.md](CONNECTED_EXPERIENCE.md#scope-and-acceptance).
Historical builds below do not validate the current branch.
Use [LIVE_TEST_HANDOFF.md](LIVE_TEST_HANDOFF.md) for the exact-commit build
procedure, three-computer library cases, receiver recovery, security and
accessibility checks, and evidence template.

## Main reconciliation for PR #71 — 2026-10-28

The follow-up incorporates main `4f177e93`, including its subtitle, motion,
connector and genre-browsing changes. PR #54 is already merged. Receiver
implementation and security regressions are retained; Windows/JVM test
registration and shared Apple test wiring remain part of private JIT CI.

This pass repairs source/API integration errors in the combined app, restores
bounded TAR parsing, keeps stale settings writes from winning, and preserves
subtitle operation serialization and widget lifetime checks. Typed subtitle
translation references prevent cleanup from silently dropping runtime messages.
New controls use the shared AppIcon/rounded Symbols styling, retaining provider
marks and a distinct filled/unfilled favorite state.
The optional library-genre capability is queried through its own interface,
preserving compatibility with clients that do not provide it.

- **524 focused Flutter tests passed** in the final combined run: Games,
  Multiview, gamepads, companion provider/receiver/peer, visualization,
  recordings, search, settings, subtitle timing/imports, source playback,
  music playback and library browsing/navigation.
  The retry regression now preserves the current session's progress revision
  while still rejecting late writes after an explicit reset or profile change.
- The repository's **standard analyzer passed with zero diagnostics**;
  formatting passed for **2,042 authored Dart files**, and icon consistency
  passed for **1,197 non-generated application files**.
- **Isolated full code generation passed**: all generated outputs match the
  committed files. The successful local run used a task-local Dart runtime
  with a bounded heap; the shared SDK and repository checks were not changed.
- **41 native Debug tests passed** with Vulkan and GStreamer enabled.
- **458 workflow/script guard tests passed** across 41 suites.
- **17 new subtitle regression tests passed**, covering ZIP/TAR/gzip-TAR,
  traversal, underdeclared expansion, octal validation, resource bounds,
  fractional drift, invalid rates and unchanged source bytes. These are
  included in the 524-test Flutter total, not additional tests.
- Localization checks pass for **37 locales / 4,265 messages**, with **18,972
  explicitly allowlisted English fallback entries**; these are not reviewed
  translations. Existing translated copy and native permission messages remain.

The standard unused-code check still reports eight existing declarations:
`IptvChannels`, `IptvProgrammes`, `IptvChannelOverrides`,
`IptvTranslationFallback`, `IntegrationConnectionRef`,
`IntegrationAccessEvidence`, `AvailabilityLookupService` and
`MotionProcessingModeSettings`. The unused-file check reports
`lib/i18n/iptv_copy.dart` and `lib/integrations/integration_offers.dart`.
These application-wide hygiene gates are unresolved; no exclusions or runner
policy changes were introduced to conceal them. The full repository test suite
is not qualified by the focused receiver/application checks. The music-player
tests pass in this combined run as well as in their earlier isolated run;
overlapping and interrupted attempts are not added to these totals.

The PR description records the final combined application checks and exact
published commit. Full SDK builds and live tests must use that revision. No new
HDR, Android/Linux direct GPU output, internet rendezvous/traversal/relay or
programmatic Cloud/Families implementation is claimed by this reconciliation.

## Earlier code handoff pass — 2026-10-28 (`f1e14bcc`)

This pass incorporates main `f0f1e104` and the startup/build hardening in
`60c8d0a4`. The PR records the final handoff commit; always check out that
revision before building. Local evidence below is not private-JIT CI or
platform/device qualification.

- **287 Flutter tests passed** across Games, Multiview, gamepads, companion
  provider/receiver/peer, visualization, recordings and search. They include
  three archive-extraction regressions, failure cleanup, existing controller
  ownership tests, and cloud-source search. The 42-test search/card rerun
  overlaps this count and must not be added to it.
- The repository's **standard analyzer check passed with zero diagnostics**.
  This covers the combined application and tests, after repairing compilation,
  async-context lifetime and fixture failures introduced by the merged sources.
- **41 native Debug tests passed with Vulkan and GStreamer enabled**. A separate
  **41-test ASan/UBSan run passed with Pyrowave disabled**, covering the portable
  transport and GStreamer receiver. Local LeakSanitizer was disabled because
  this environment cannot inspect the required process state; private CI keeps
  leak detection enabled. Neither run establishes Vulkan GPU execution.
- Real GStreamer H.264 red-pixel decoding now passes both Annex-B and
  avcC/length-prefixed framing. Runtime tests cover bounded connection and
  first-frame waits, cancellation wakeups and tracked presentation evidence.
- Windows transport, Media Foundation/XAudio2 receiver and five test executables
  cross-compile/link with MinGW-w64. Strict Windows and Linux Flutter adapter
  syntax/type checks and the JNI check pass. This is not MSVC or Windows test
  execution, nor a complete Linux app/package build.
- All Android Steam Java sources compile against Google's real API 36 classes
  with real AAPT2-generated resources. **15 Java JUnit tests pass**, including
  decoder-worker joining/interruption. Nineteen compatibility deprecation
  warnings remain. The repository's SDK pins were preserved; these checks do
  not replace its API 37 Gradle/NDK and minified-release builds.
- **458 workflow/script guard tests passed**, including eight tvOS wiring
  regressions and nine Steam source/archive tests. The Apple archive tests
  verify transactionality, architecture checks and transitive crypto inputs
  using mocked build commands; they do not compile an Apple SDK target.
- Translation normalization, placeholder/source-hash checks, native localization
  and localized quantities pass for **37 locales / 4,200 messages**, with
  **16,632 explicitly allowlisted English fallback entries**. Removed ten unused
  keys and normalized missing keys to the existing empty-string fallback
  convention. This does not constitute language review.

Current-head private-JIT CI, Windows MSVC/execution, Apple SDK/Metal tests,
Android Gradle/NDK/release builds and real-host qualification remain required.
HDR presentation, Android/Linux direct GPU Pyrowave, automatic internet
rendezvous/traversal/relay, and programmatic Cloud/Families mutations remain
implementation gaps, as detailed in the handoff. Do not describe them as
completed features awaiting only live testing.

Historical evidence begins on 2026-10-26; PR #54 follow-up records appear below.
The earlier platform/codec descriptions are snapshots, not the current support
matrix. Use [ARCHITECTURE.md](ARCHITECTURE.md#platform-matrix) for current source
coverage. This is experimental implementation, not certified streaming support.

## Evidence

- GitHub Actions [run 40295331169](https://github.com/snapetech-org/PlezyNG/actions/runs/40295331169), commit `a948f57c74d3c908984c8b21d82c5d662e2414d3`: **Moonlight Android library/JNI/adapter build passed**. This run predates the new Steam module and does not validate it.
- Historical GitHub Actions [Games embedded engine run 40356122282](https://github.com/snapetech-org/PlezyNG/actions/runs/40356122282), commit `ecf7759a989f8aa6d708978e6cfb3ada8420939e`, and [run 40357578204](https://github.com/snapetech-org/PlezyNG/actions/runs/40357578204), head `3cd7f91bdb1fbc40007c428750a2abf04bd0659c`: both Android library builds and all 38 portable transport/adapter tests passed with sanitizers. These runs came from the now-removed standalone workflow, which used GitHub-hosted `ubuntu-latest`; they are historical test evidence, not validation of current runner routing.
- The standalone Games workflow has been removed. Current Games tests are integrated into the existing private JIT-routed `android-test` and `linux-native-test` jobs in `.github/workflows/ci.yml`, whose job IDs are already present in the shared runner inventory. The temporary localization-generation workflow was also removed; checked-in localization output is verified by the existing JIT-routed code-analysis job.
- Flutter 3.47.1: **64 focused tests passed** on the combined Games/latest-main tree. Full Dart analysis reports no issues. Structural localization checks pass for 37 locales and 3,146 messages, with placeholders/source hashes verified; localized quantity generation is current.
- The 38 native tests cover authorization, crypto, launch transactions, retransmission, HID, tracked-frame ownership, cancellation, late callbacks and Pyrowave parsing/negotiation. CI runs the Steam suite with AddressSanitizer, UndefinedBehaviorSanitizer and leak detection.
- On the earlier head, Code Analysis run [40357578052](https://github.com/snapetech-org/PlezyNG/actions/runs/40357578052) detected stale generated `strings_*.g.dart` outputs; these were regenerated and committed in `6ca060b8f4e29d95a0a9b18b3720292884524401`. That historical run's iOS job also stopped at the CocoaPods lockfile-preservation check after Flutter configuration changed `ios/Podfile.lock`; current-head CI is needed to establish whether that issue remains. Android host-native and JVM/API checks passed in run [40356122352](https://github.com/snapetech-org/PlezyNG/actions/runs/40356122352).
- All six Android Steam Java sources compile against Google's real Android API 36 stubs with Java 17; five expected compatibility deprecation warnings remain. Linux JNI syntax/type checking passed with strict warnings. The embedded-engine workflow also verifies the Android module builds, while full app/minified release and device testing remain release gates.
- Two Python tests passed for private embedded manifests and cancellation patches. Source preparation accepts the pinned Steam recipe. Native C/C++/Java formatting and Kotlin ktlint passed.

The focused Flutter coverage includes malformed Steam discovery packets, the UDP-versus-TCP port distinction, manual host identification, profile persistence/deletion, retired async operations, failed refresh preservation, missing engines, structured native launch arguments, cover backpressure, PIN cancellation, large RTL text, shared poster focus and rail navigation. Additional Steam tests distinguish a Big Picture route from account inventory and preserve user-added shortcuts during refresh.

Reproduce:

```sh
flutter pub get --enforce-lockfile
flutter test test/games test/navigation/navigation_tabs_test.dart test/widgets/side_navigation_rail_test.dart
flutter analyze
python3 -m unittest discover -s scripts/games -p 'test_*.py'
python3 scripts/games/prepare_steam.py
cmake -S native/games/steam -B build/games-steam-tests -DPLEZY_STEAM_TESTS=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build build/games-steam-tests --parallel 2
ctest --test-dir build/games-steam-tests --output-on-failure
cd android
./gradlew :moonlight:assembleDebug :steam:assembleDebug
```

The private JIT-routed `android-test` job builds both Android libraries alongside existing Android JVM/native checks. The private JIT-routed `linux-native-test` address-sanitizer matrix entry runs the portable Steam transport/adapter suite with AddressSanitizer, UndefinedBehaviorSanitizer and leak detection. Ordinary Android CI must also compile the application integration and minified release. No local APK, live Steam OpenID exchange, API-key-backed catalog request, live PIN exchange, actual hardware decode, controller-latency measurement, or real stream was performed: this environment has no gaming host or GPU device. The new server and client paths have not been run here; current-head private-JIT CI is the first implementation check. The CodeQL init/analyze actions now run inside the existing private-JIT `android-test` job. Repository security settings must switch from CodeQL default setup to advanced setup before GitHub will accept SARIF uploads from that workflow.

New Games messages are seeded with reviewed English fallback copy in non-English base locales; they are **not language-reviewed translations**. Regional locales inherit their parent. Latest-main localization fixes are preserved independently of these new keys.

## Required before Android release

1. Build debug and minified release APKs for supported ABIs. Verify manifest merging, app identity, backup exclusions, private components, merged resources and shrinker retention. Test with the embedded module enabled and with `-PplezyGamesEmbedded=false`.
2. Sunshine stable/current, Apollo, Wolf and representative legacy GameStream hosts: discovery, manual address/custom port, correct/wrong/expired PIN, rejection, certificate change, reconnect and revoked trust. Confirm no host credentials or trust material enter logs, QR codes, profile exports or backups.
3. Android phone/tablet, Android TV and Fire TV: qualify GameStream codecs/HDR/refresh/input features independently from Steam. Steam currently negotiates at most 1080p60 conventional video and stereo Opus, with one controller by default (up to four selectable seats), fixed touch overlay and basic keyboard. The retained Multiview surface and full-screen Activity share a decoder implementation, but PlatformView/SurfaceView composition, frame latency, clipping, workspace audio/input leases and reconnect after pane unmount are unverified. Pyrowave is off by default per profile; after explicit opt-in and a successful Vulkan probe, its experimental Android path adds bounded SDR 4:2:0 decode with CPU readback; measure first-frame delay, dropped frames, CPU/GPU load, thermals and battery against H.264/HEVC on actual hardware. Rumble, gyro, full IME, multiple pads, AV1/HDR and Pyrowave performance are not release-qualified for Steam. Record exact hardware and host/client versions.
4. Rotate/background/suspend, change profiles or disable Games during pairing/library/art requests, disconnect the network, and reopen repeatedly. Confirm cancellation, multicast-lock release, independent per-pane session teardown, no late launches, and sane media/audio restoration.
5. Missing, malformed, oversized and slow cover art; large libraries; empty app list; offline refresh; multiple computers with duplicate game names. Confirm cards remain usable without artwork.
6. Package the pinned modified engine's complete corresponding source, build instructions, dependencies and required license notices with each distribution. Review all third-party components and distribution-channel compatibility. The Moonlight and Steam notice assets alone are not a complete corresponding-source release bundle.

## Remaining gates

- **Steam interoperability:** current stable/beta and representative older hosts, correct/wrong/expired PIN, host rejection, revoked trust, selected-game launch, input and decoder behavior. A compiled independent protocol implementation is not host certification.
- **Steam account and catalog:** browser-based Steam OpenID identity linking and bounded import of public owned-game metadata are implemented. Configure `STEAM_WEB_API_KEY` on the server for catalog retrieval; without it, account identity still links but the catalog is unavailable. The import does not expose private libraries or establish host installation. A catalog tap uses a matching saved Steam host shortcut and requires host-side launch acceptance. Validate public/private profiles, stale refresh retention, account switching, 2,000-item truncation, QR/browser flow, Steam Guard prompts handled by Steam, and the server's configured callback in the current private-JIT run. See [STEAM_LIBRARY.md](STEAM_LIBRARY.md).
- **Pyrowave:** Android negotiation, pinned Vulkan decoder, bounded block parsing, SDR 4:2:0 CPU readback/Canvas presentation and reconnect fallback are wired. A profile-scoped opt-in now defaults off and gates codec advertisement alongside the Vulkan decoder probe. Regenerate the checked-in localization outputs before merging, then verify the switch and warning on Android. Confirm Steam framing, partial-frame behavior, clean fallback, phone/TV performance and release notices against real hosts/devices. HDR, 4:4:4, direct GPU surface output, Metal and non-Android adapters remain unimplemented.
- **Platform ports:** only Android has native playback adapters in this change. The shared Games UI and Linux-tested portable Steam core do not provide desktop/Apple/webOS playback. See [ARCHITECTURE.md](ARCHITECTURE.md).

No external streaming-app handoff is used.


## Connected experience PR #46 — 2026-10-28

- Dart analysis of Games, Games screens, companion provider and OAuth client:
  no issues.
- Focused Flutter Games, all Multiview, companion provider/receiver/peer and
  OAuth poll regression suite: **158 tests passed**.
- `go test -race ./...` in `server`: both packages passed, including catalog
  identity binding, credential rejection, rate limiting, expiry, revocation
  and concurrent revocation during an upstream fetch.
- New inventory fixtures cover multiple Steam drives, three different gaming
  computers in one grid, malformed manifests, cancellation, opt-in sharing,
  multi-page transfer and out-of-order response rejection.
- No native Android build or attached-device qualification has yet been run
  for the new Java/Kotlin first-frame callback. Desktop browsing/inventory
  support does not mean a desktop streaming receiver is available.

### Stream preferences and recovery follow-up

- Games/Multiview Flutter suite: **99 tests passed**. After adding the late
  replay regression, the final session test file passed **6 tests**; these
  counts overlap and must not be added to the earlier 158-test suite.
- Focused Dart analysis: no issues. Recovery tests cover first-frame input
  gating, duplicate reconnect taps, teardown failure, stale state replay and
  profile retirement during shutdown.
- Portable Linux Steam/Pyrowave C++ build: successful. **38 native tests passed**
  across the initial run and a targeted timer rerun. The initial timer test
  could not execute because its generated binary lacked its executable bit;
  repairing that local build-file permission allowed it to pass. This run was
  Debug without sanitizers; it is not a replacement for sanitizer CI.
- Native request test inspects the transmitted resolution and rejects invalid
  limits before a connection. Strict host-JDK JNI syntax/type check passed with
  upstream headers treated as system includes, matching the CMake target.
- Java 17 compilation and JUnit: **6 option/controller tests passed**, including
  legacy defaults, explicit H.264, integer overflow, wrong types and excessive
  limits. This compiles the platform-independent Java classes, not the Android
  SurfaceView, Kotlin adapter or APK.
- Android debug/minified release builds, live reconnect/quality negotiation,
  other platform receivers and hardware performance remain outstanding.

### Steam activity and companion host-action follow-up

- Games plus companion provider/receiver/peer Flutter suite: **128 tests passed**.
- Focused static analysis of Games, its screens and companion implementation:
  no issues.
- Go server race suite passed in both packages after adding metadata endpoints
  and global/per-grant request bounds. Tests cover identity selection rejection,
  optional social reads, hidden spoilers, revocation during a fetch, redirects,
  oversized upstream data and request validation.
- Host-action tests cover strict URI construction, opt-in permission, replay
  rejection, unknown command arguments, peer retirement and permission changes
  during async inspection. Acknowledgements establish submission only.
- Live Steam API credentials/relay deployment and real OS Steam URI handlers
  were not exercised. These results do not validate new native receivers or
  automatic internet streaming; those implementations remain outstanding.


### Independent controller seats follow-up

- Focused Flutter preference/session/gamepad suite: **20 tests passed**. It
  verifies device IDs reach the native boundary, disconnect releases one
  controller, ownership loss releases all input, and legacy/profile defaults.
- Java 17 compilation and JUnit: **11 tests passed**, including shared input
  paths, independent held states, slot reuse, excess-device rejection and
  neutralization without reordering. These are platform-independent classes,
  not an Android APK build.
- Portable native Debug build and **38 native tests passed**. The regression checks independent
  pad state, unique HID identities, invalid seats/counts, and four-controller
  negotiation in the actual serialized streaming request.
- Strict host-JDK JNI syntax/type check passed. Full Android compilation,
  minification and real multi-controller/host behavior remain unverified.


### Native stream diagnostics follow-up

- Focused metrics/dialog/session Flutter suite: **14 tests passed**. Coverage
  includes missing targets, fractional host rates, counter deltas, reconnect
  epochs, backwards timestamps, unknown native versions, old native modules,
  input lease changes while a dialog is open, and polling teardown. The dialog
  is exercised at 320px width with RTL and 2× text.
- Portable native Debug build and **38 native tests passed**. Adapter tests
  assert duplicate frame callbacks do not inflate counts, reset frames remain
  separate, malformed host targets are ignored and receiver epochs are unique.
- Strict host-JDK JNI syntax/type check passed. Full Android packaging and live
  host adaptation/latency measurement have not been run.


### Companion game-session controls follow-up

- Games, Multiview, companion provider/receiver/peer suite: **194 tests passed**.
  This includes permissions, replay rejection, unknown commands, stale/replaced
  handles, disconnect during work, bounded replies, game-only workspace actions,
  audio isolation and a timed-out host-inspection regression.
- Two additional dialog tests passed: connection retirement suppresses a late
  title, and game-session actions fit a 320px RTL dialog with 2× text.
- Focused Dart analysis of the changed implementation and tests: no issues.
- These are local automated results. Current-head private-JIT builds, real
  companion devices and actual Steam host actions remain unverified.


### TV navigation compatibility follow-up

- Java controller/options suite: **13 tests passed** after separating navigation-
  only remote buttons from physical controller seat allocation. A single-seat
  stream still accepts its first physical pad after TV-remote input; composite
  device removal releases both paths without clearing another player's state.
- Android SurfaceView compilation and physical TV input remain release gates.

### Linux receiver and multichannel audio

The local Debug native suite now includes a dedicated GStreamer H.264 decoder
fixture (real encoded frames, RGBA pixel values, audio reconfiguration and
teardown), and Opus mono/stereo/quad/5.1 speaker-isolation tests. Android Java
sources were type-checked against API 36 with resource-name constants generated
from the module's actual XML; this is **not** an APK/Gradle/resource packaging
build, and the project still targets compileSdk 37. JNI strict compilation passes.
Linux Flutter adapter translation units compile with `-Wall -Wextra -Werror`.

The native CI recipe enables GStreamer tests on its existing private JIT job.
No private JIT run, live Steam host, speaker/AVR, Linux full-runner release,
Flatpak keyring, Apple SDK or Windows receiver validation has run locally.

The Linux/texture follow-up passed 154 Dart/widget tests and 40 native Debug
tests, plus strict Linux adapter compilation. The isolated GStreamer queue/
decoder test also passed AddressSanitizer and UndefinedBehaviorSanitizer. Local
LeakSanitizer could not inspect `/proc` under this environment, so leak detection
remains enabled in private JIT and is not claimed as locally passed. Workflow
security, action-pin and architecture checks passed; no runner routing changed.

### Configuration/account affordances — PR #54

- 50 focused Flutter action, metadata, large-text RTL menu and companion-provider
  tests passed. New tests reject malformed capability lists and AppIDs, preserve
  older peers' action set, and verify that Cloud/Families destinations are fixed.
- Localization checks passed for 37 locales / 3,725 messages; the new messages
  and the surround-audio copy explicitly use reviewed English fallback until
  translations are available.
- Live Steam Input/properties URI behavior, browser sign-in and account changes
  were not exercised. No cloud save was written and no family membership changed.


### Apple source and texture-input follow-up

- Portable native Debug build with Vulkan/GStreamer enabled: **41 tests pass**,
  including the new H.264/HEVC framing parser, real encoded H.264 fixture,
  malformed-input bounds and transactional parameter-set updates.
- Portable build with Vulkan disabled: 40 tests passed before the shared pointer
  additions; this validates the transport/parser dependency split, not Apple
  system frameworks.
- Focused shared input/texture/platform tests: **43 Dart/widget tests pass**.
  They cover full keyboard routing, inactive lease suppression, Shift+Escape,
  pointer bounds, physical usage codes, texture retention and reconnect after
  a channel has been retired.
- Xcode project structure is checked locally; a VideoToolbox XCTest is added
  to each RunnerTests target. Apple SDK compile, Swift/Objective-C++ linkage,
  simulator test execution, real host pairing, color correctness, performance,
  HDR output and surround speaker routing have **not** been run here.
- The Apple source uses a direct CVPixelBuffer texture path for conventional
  SDR codecs. Direct Pyrowave, HDR/4:4:4, Windows receivers and automatic
  internet traversal remain separate unfinished work.


### Metal Pyrowave source follow-up

The pinned Metal library, app-owned GPU conversion and texture adapter are
wired into all Apple targets. Source/project checks verify compilation inputs,
framework linkage and archive wiring. Portable parser tests now cover opt-in
4:4:4, siting, legacy 4:2:0 rejection, conflicting sequence headers and HDR
rejection. This does not validate Metal shader compilation or GPU execution.
The checked-in Apple XCTest must run on compatible Apple private-JIT hardware.
The Intel/simulator skip is explicit and is not a successful GPU test.

Local follow-up checks: all **41 native tests** and **20 focused Dart/widget
tests** passed after these changes, including the narrow RTL diagnostics view
with Metal/chroma labels. Focused Dart analysis reports no issues. Structural
localization checks pass for 37 locales and 3,728 messages. These counts do not
include the Apple-only decoder tests.


### Touch assistance and ownership

The shared Apple/Linux overlay uses the existing theme and connection toolbar.
Native runtime tests verify that assistance shares player one without consuming
a controller seat, and that hiding touch controls or unplugging a controller
does not clear another input source. Multi-touch widget tests cover simultaneous
buttons, cancellation, 48-pixel semantics targets at double text size in RTL,
clamped sticks, stick clicks and resizing guidance. Apple GPU and device checks
remain outstanding; Flutter gesture tests do not validate an iOS touch driver.

After fixing late pointer cancellation during disposal, **27 focused
touch/texture/workspace/gamepad tests pass**, including removal of a held
control when its input lease is revoked. Focused Dart analysis is clean. The
portable runtime test passes the separate assistance/physical-pad merge cases,
and the Linux adapter passes strict compilation against Flutter's headers.

### Combined PR #54 verification after merging main

- Merged main `574e5420`, preserving the media-player work, reviewed locale
  translations, private ephemeral JIT routing and manual workflow triggers.
- **192 Games/Multiview/gamepad/companion Dart and widget tests passed**.
  After the final accessibility-label changes, all six focused touch/texture
  regressions passed again. Counts overlap; they are not additive.
- **41 portable native Debug tests passed**, with Vulkan and GStreamer enabled,
  after formatting and fixing Pyrowave's required Vulkan-header include order.
  Strict Linux Steam adapter compilation passed against Flutter 3.47.1 headers.
- **46 packaging/workflow tests passed**, plus two source-preparation tests.
  These are packaging contracts, not a full Linux application/package build.
- Focused Dart analysis is clean. Source hashes and placeholders pass for
  37 locales / 3,790 messages. New control labels use explicit English fallback;
  they are not presented as reviewed translations.
- Touch layouts were rendered at 800×400 and 390×750, with RTL and double-sized
  text, for visual inspection. Existing theme and icon assets are reused.
- Xcode project structure verifies all three Apple source sets, archive build
  order, framework links and test inclusion; existing minimum OS versions are
  unchanged. This is not SDK compilation or GPU execution.
- Current-head private-JIT CI has **not** run. Workflow dispatch is unavailable
  through the connected GitHub API, and the available browser is not signed in.
  Apple SDK/device validation and full platform build/release gates remain open.

To run the existing private workflow from an authenticated maintainer session:

```sh
gh workflow run ci.yml --repo snapetech-org/PlezyNG \
  --ref codex/steam-receivers-and-controls \
  -f action=ci -f runner_pool=private -f build_linux_packages=true
```

Verify the run's head matches the PR head. A rerun of an older workflow revision
does not validate these sources. No hosted fallback is authorized.


### Windows receiver source and cross-compilation — 2026-10-28

- The shared transport, Windows Media Foundation/XAudio2 adapter and five
  Windows test executables compile and link with MinGW-w64 GCC 13.2. The
  Flutter Windows plugin passes `-Wall -Wextra -Werror` syntax/type checking
  against Flutter 3.47.1 headers. This is **not MSVC or Windows execution**.
- The new tests exercise actual loopback UDP, oversized datagram rejection,
  receive timeouts, recursive locks/conditions, pairing cancellation and a
  real 64×64 H.264 red-pixel fixture. Their Windows execution is still pending.
- All three native source patches replay cleanly against the pinned IHS
  revision and reproduce the prepared source. Shared IHS compilation also
  succeeds with variable-length arrays rejected, for MSVC portability.
- **41 Linux native tests passed across the run and targeted rerun**. Two
  rebuilt test binaries initially lacked executable permissions; restoring
  those local generated-file permissions allowed both to run and pass.
  The later Annex-B normalization regression passes independently.
- **24 focused Flutter tests passed** for workspace/session lifecycle,
  textures, native capability behavior and accessible touch controls. Focused
  Dart analysis is clean. These overlap the earlier 192-test suite.
- **46 packaging/workflow contract tests passed** after the workflow extension.
- Private Windows CI now builds and runs the Steam tests alongside existing
  native checks, preserving x64/ARM64 private JIT routing and manual dispatch.
  Current-head CI, Apple SDK builds, Windows N startup, Windows audio devices,
  actual host playback and GPU/HDR qualification remain open.

### Android/Wayland Vulkan receiver source checkpoint

- 42 native tests pass; the additional hardware Vulkan/Wayland test skips in
  this container (no qualifying hardware device). The actual software decode
  attempt failed inside Mesa/LLVM; see [VULKAN_RECEIVER.md](VULKAN_RECEIVER.md).
- 25 focused Flutter tests pass, including the native-plane/texture switch and
  retirement channel contract, aperture transparency and narrow RTL diagnostics.
- Linux plugin/Wayland sources pass strict syntax checks against Flutter/GTK
  headers. Android Java compiles against API 36; no Android NDK build is claimed.
- Shader regeneration matches the committed SPIR-V. Nine source/build guard
  tests and 225 check-script tests pass (the two Dart-dependent checks were
  rerun with the required toolchain PATH after an initial environment error).
- Apple SDK, MSVC, full Linux/Android packages and physical HDR output remain
  unqualified. These checks do not establish a successful real Steam session.

### Scoped Steam Cloud checkpoint (2026-10-28, PR #81)

- `go test -race ./...` passed, including new Cloud OAuth identity/origin/replay,
  grant expiry/revocation, permission/configuration, bounded transfer deadline,
  SHA conflict, storage/integrity and mandatory finalization failure tests.
- 18 focused Flutter tests passed: Cloud client/dialog, existing activity
  panel/client and OAuth polling/dialog. The Cloud flow uses a 360-pixel RTL
  viewport at 1.7× text, separate write authorization, a reviewed deletion and an
  ambiguous-response refresh requirement. No analyzer issues in the six changed
  Dart source/test files. Locale generation and normalization checks passed.
- Live Valve OAuth approval/scopes, actual storage endpoints/response schemas,
  platform pickers and real save changes remain unqualified. See
  [STEAM_CLOUD.md](STEAM_CLOUD.md) for configuration and a disposable-save handoff.
  Confidence: high in the recorded local checks; unknown in live Valve/device
  behavior. Families membership mutation is not implemented.

### Paired internet checkpoint (2026-10-28, PR #81)

- `go test -race ./...` passes, including relay same-account admission,
  wrong/expired/revoked grants, origin/header checks, third-peer rejection,
  bounded frames/queues, paired disconnect and disabled/insecure configuration.
- **43 Flutter tests pass** for the new authenticated packet codec, real
  localhost TLS/WSS/UDP upgrade/fallback fixture, Companion provider and Games
  dialogs. The two network tests were rerun after adding retained-workspace
  identity, loopback mapping, compatible-codec, route-label and retirement
  assertions; they pass and are included in the 43, not additional tests.
- **24 existing native-client/workspace/texture/diagnostics Flutter tests pass**
  after the tunnel lifecycle integration. This is a separate focused set; it
  does not qualify the full app test suite.
- The repository's **standard analyzer passes with zero diagnostics**. Slang
  generation, translation normalization/unused-key checks and locale validation
  pass: 37 locales, 4,280 messages and 19,512 explicit English fallback entries.
  The Cloud/internet source hashes record the current reviewed English copy;
  these fallbacks are not language-reviewed translations.
- **42 native tests pass; one hardware Vulkan/Wayland test explicitly skips**.
  Native routing rejects incomplete/duplicate/non-loopback proxy mappings.
  Linux adapter/Wayland and Windows adapter strict syntax checks pass; Flutter
  SDK headers are external system includes in the Windows check. The portable
  Windows runtime/receiver and tests cross-compile/link with MinGW-w64. None of
  this is MSVC or Windows execution.
- The Android Steam Java module compiles against API 36 with generated resource
  symbols and 20 compatibility deprecation warnings. The new JNI entry point
  preserves all older entry points, but Android NDK/link/minified packages and
  current Apple SDK builds still require private JIT verification.

See [STEAM_INTERNET.md](STEAM_INTERNET.md) for the disabled-by-default deployment,
two-device opt-in, same-account admission, fixed-port forwarding, cryptographic
and resource limits, and real-network test matrix. No real internet relay
deployment, router traversal, Steam session throughput, hardware HDR output or
independent cryptographic audit was performed here. Current-head private JIT
jobs have not been dispatched from this environment; use the commands in
[LIVE_TEST_HANDOFF.md](LIVE_TEST_HANDOFF.md). Confidence is high in the recorded
local results and unknown in untested device/service/network behavior.

## Windows/Apple HDR source checkpoint — 2026-10-29

- Windows x64 MinGW build now enables Vulkan/Pyrowave and links all five native test executables. Strict Windows adapter syntax checking passes. These executables were cross-built, not run on Windows.
- Linux Vulkan/GStreamer rebuild passes; native regression results are recorded with the checkpoint.
- Seven Steam source-preparation and Apple archive-script tests pass.
- Apple tests now decode HDR 4:2:0/4:4:4 into RGBA16Half, check actual half-float output and reject unannounced color changes. They require an Apple SDK and compatible GPU; no result is claimed here.
- MSVC x64/ARM64, Apple SDK builds, Android NDK builds and physical HDR displays remain required. See [DESKTOP_HDR.md](DESKTOP_HDR.md).

## Families and HDR follow-through — 2026-10-29

- The full server `go test -race ./...` passes, including the new Families
  policy, QR identity, one-use review, credential/redirect, account isolation,
  shutdown cancellation and revocation cases.
- Seven focused Flutter tests pass: four Families client cases, the explicit
  review/acknowledgement/uncertain-result/retirement flow in normal and narrow
  2x-text RTL layouts, and the existing Steam activity panel large-text case.
  Review/editor/error transitions reset the scroll position; the test asserts
  the actual controls are hit-testable before interacting.
- Linux native rebuild and strict adapter/Wayland syntax checks pass. The
  native suite reports 42 passes and one explicit hardware-dependent Vulkan
  skip, with no failures.
- The Windows MinGW Vulkan/Pyrowave runtime and five native executables rebuild
  and link after correcting native Win32/Vulkan include ordering. These are
  cross-build results, not Windows execution or MSVC validation.
- Strict Windows adapter syntax checking and the standard Dart analyzer pass
  with no diagnostics. Localization and strict normalization/usage checks pass:
  37 locales, 4,309 messages, 20,556 explicit English fallback entries and no
  unused translation keys. The fallback entries are not reviewed translations.
- Apple HDR presentation failure now cancels the Pyrowave session so the
  existing conventional-codec reconnect path can recover. Windows/Linux
  diagnostics report chroma only after an actual GPU-presented frame.

These tests use controlled Steam API responses and do not claim successful
Families changes on live accounts. Current private-JIT SDK builds, real HDR
output, relay deployment and Valve-approved Cloud scopes remain external gates.
See [STEAM_FAMILIES.md](STEAM_FAMILIES.md) for the broader temporary-session trust
model, explicit limits and live qualification cases.

## Fixed-base application integration — 2026-10-29

The PR branch incorporates base `ac97859268aeddde1c112628debaac4ccc496c34`.
Integration repairs keep the newer player-neutral subtitle capture interface
supplied with position/duration, explicitly narrow optional native audio and
PCM capabilities, expose the app-owned Tizen native handle without using a
test-only API, restore the missing base64 import and check widget lifetime after
asynchronous subtitle validation. Changed Dart sources are formatted with the
repository toolchain. These changes preserve the source features on that fixed
base; this checkpoint does not merge or deploy the PR.

The existing playback regression tests also exposed a constant operation ID:
every seek, relocation and source change reused zero. Restoring monotonic IDs
allows accepted newer operations to supersede stale completions without letting
a rejected request take ownership.

- All 88 native-player bridge and Tizen tests pass after this repair, including
  overlapping, rejected and out-of-order seeks and source retirement.
- A separate 119-test regression run passes for music playback, music
  visualization, signed visualization catalogs, subtitle archive imports and
  source playback.
- All 29 selected Steam card, Families client/dialog, activity, real localhost
  internet-tunnel fixture and retained workspace/texture tests pass on the
  reconciled source. This includes narrow 2x-text RTL confirmation and native
  plane/texture recovery. Together these three non-overlapping runs contain
  236 passing Flutter tests; they do not qualify the entire application suite.
- The standard Dart analyzer passes with zero diagnostics. Localization checks
  pass for 37 locales, 4,309 messages and 20,556 explicitly recorded English
  fallbacks; these counts do not imply reviewed translations.
- Formatting passes for all 51 changed authored Dart files. Earlier interrupted
  or compiler-memory-limited test attempts are excluded from the passing totals.
  The successful focused runs used a task-local bounded compiler launcher;
  shared SDK files and repository checks were not altered.

## Current-main reconciliation — 2026-10-29

The final handoff incorporates actual main tip
`86c852ee3267c955d557f2e9aa6be1dc8080a2ce`. The PR metadata had still reported the
older base while the branch reference had advanced by 12 commits. Both semantic
conflicts are resolved using main's equivalent monotonic playback-operation
fix and explicit PCM capability cast. Its unified PCM timing and public Tizen
handle contract replace the duplicate compatibility accessors from the previous
checkpoint. Steam features and security controls are retained.

Current-main SDK cache, private-runner routing, platform build repairs, database
generation and test-fixture changes are retained. The workflow architecture
guard passes, and formatting passes for all 30 authored Dart files that still
differ from this base. These source checks do not establish a private-JIT build.

- The standard analyzer again passes with zero diagnostics; localization
  counts and explicit fallback tracking remain unchanged.
- All 88 native-player bridge/Tizen tests pass again on this combined source.
  Initial compilation exceeded the earlier compiler heap cap; the
  successful retry used a larger task-local cap, with the shared SDK unchanged.
- All 119 music, visualization, subtitle-import and source-playback tests pass
  again, including main's revised signed-catalog fixtures.
- All 29 selected Steam UI/client, real TLS/UDP tunnel, workspace and texture
  tests pass again. These three non-overlapping current-main runs total 236
  passing Flutter tests. The earlier checkpoint's totals are not additional
  tests and do not qualify the final source on their own.

Native Steam, server, Games and Steam detail-screen source files are unchanged
from the preceding implementation checkpoint. Their recorded native/server
results remain separately identified above; no new SDK build or live deployment
is claimed. This reconciliation resolves source conflicts without merging the
PR into main or changing the required private-JIT platform qualification gates.

## Code follow-through — 2026-10-29

Checkpoints `4d8c8add` (session ownership/internet codecs), `1465511c`
(controller layouts) and `35d7e8bd` (host controls/UHD/relay budgets) are followed
by committed IME text and touch appearance. All remote writes use the GitHub
connector; PR #81 targets main `86c852ee`. No workflow trigger, runner pool or
trust rule changed.

Latest source verification:

- **141 Flutter tests passed**: all `test/games` plus the Steam workspace session
  and texture suites. Coverage includes local TLS/UDP traversal/fallback,
  inventory/account isolation, Cloud/Families reviews, mapping rollback/replay,
  IME commit gating, UTF-8 bounds, touch-side geometry, large text and retirement.
- Standard analyzer passed with zero allowed info diagnostics. Localization
  placeholders/source hashes pass with explicit English fallback tracking;
  this is not a translation review.
- Linux native build: **42 tests passed; one GPU/display test skipped**.
  Native text tests reject overlong/truncated/surrogate UTF-8, controls and
  oversized buffers. Runtime tests cover controller mappings and request bounds.
- Windows MinGW runtime and five native test executables compile/link. Linux
  and Windows Flutter adapter syntax checks pass with warnings treated as errors
  for application source; vendored SDK headers are system includes.
- Android Java compiles against API 36 with 20 existing deprecation warnings;
  **16 JVM tests passed**, including updated quality bounds, controller seats,
  legacy defaults and worker lifecycle. Reflection methods are explicitly kept
  for shrinking. This is not Kotlin/Gradle/NDK packaging qualification.
- Full server `go test -race ./...` passed after the relay bandwidth changes;
  the later input work does not change server source.

No Apple SDK, Android release package, MSVC execution, hardware HDR/chroma,
production relay deployment or live Valve account mutation is claimed. Follow
[CODE_COMPLETION.md](CODE_COMPLETION.md) for the remaining contract/code boundaries
and [LIVE_TEST_HANDOFF.md](LIVE_TEST_HANDOFF.md) for exact-commit build cases.

## Microphone source checkpoint — 2026-10-29

- 26 receiver/ownership Flutter tests pass, including late-start revocation,
  permission/device rejection, explicit opt-in and dialog/lease muting.
- Standard analyzer passes with zero diagnostics.
- 42 native tests pass; one independent display test is skipped. Real Opus
  round trips cover mono/stereo at 8/12/16/24/48 kHz, split frames and buffer
  clearing. Runtime tests race capture submission against 100 host channel
  start/stop cycles and reject expired leases and overlapping capture workers.
- Android Steam Java compiles against API 36 with the same 20 deprecation
  warnings. Windows MinGW compiles and links the WASAPI implementation into
  the receiver test executable. Linux adapter syntax checks pass under Werror.
- Apple capture, microphone entitlements/privacy text and tvOS availability
  guards are source-integrated; Apple SDK compilation is still required.

Kotlin/Gradle/NDK, MSVC, signed Apple builds and permission/device/Steam-host
qualification remain handoff checks. No live microphone or user audio was
accessed during these source tests.

## Controller and touch completion — 2026-10-29

- **171 Flutter tests passed**: all `test/games`, Steam workspace and texture
  suites, `test/services/gamepad_service_test.dart` and the vendored gamepad wire
  format suite. New cases cover physical device routing, stale claims/polls,
  malformed feedback, cancellation of pending timers, window focus loss,
  touch persistence/collision/resize, drag editing, large text and accessible
  position controls. The ordinary input wire-format regression cases pass.
- Standard analyzer passes with zero diagnostics. Localization placeholders,
  explicit English fallback manifest and source hashes pass; translation review
  is not implied. The private-JIT workflow architecture guard passes unchanged.
- **42 native tests passed; one display test skipped**. The extended runtime
  test also passes after its final feature-report assertions: fragmented/multiple
  host commands, duration bounds, stale motion, ownership loss, seat reuse,
  explicit virtual controller identity and zeroed reserved bytes.
- Windows MinGW runtime and five test executables compile/link. Strict Linux and
  Windows Steam adapters pass; the Linux gamepad extension and Windows extension
  compile with warnings treated as errors (upstream unused parameters excluded).
  Windows checks use real SDL3 3.2.8 headers fetched through the GitHub connector,
  not local stubs. Flutter's event-channel header requires C++20 for the vendored
  Windows plugin; the existing Steam runtime remains C++17.
- Android Steam sources and the controller-effects extension compile against API
  36, with 22 deprecation warnings (20 existing plus two compatibility vibrator
  calls). **16 Android JVM tests passed**. Java compilation does not compile the
  Kotlin bridge or package/link the NDK receiver.
- No server behavior changed after the previously passing Go race suite. No
  workflow, JIT policy, trust boundary or runner deployment was changed.

Build/live gates remain: current-head Apple SDK and signed app builds,
Kotlin/Gradle/NDK packaging, MSVC builds/execution, physical controllers and
motion axes, microphone permission/device paths, actual HDR/chroma presentation,
Steam host/account interoperability, approved Cloud authority and deployed relay
NAT/throughput tests. This is a source handoff, not hardware or deployment approval.

## Input ownership and accessible adjustment — 2026-10-29

- **174 distinct Flutter cases pass**: 147 Games/texture/gamepad/wire-format
  cases from the broad regression run and the final 27-case receiver/touch run.
  New delayed-reset cases reproduce the old grant overwrite on the previous
  source, with and without receiver replacement, and pass with the ownership
  fix. The touch semantics case verifies the merged control/axis/value and
  invokes screen-reader increase/decrease actions to move only the chosen axis.
- Standard analyzer passes with zero diagnostics; formatting and diff whitespace
  checks pass. The existing large-text touch editing case remains green.
- Native, vendored controller-plugin, transport/server and platform build files
  are unchanged from the preceding checkpoint. Their recorded source-check
  results and the outstanding SDK/device/service qualification gates still
  apply; this follow-up does not claim new platform builds or live testing.
