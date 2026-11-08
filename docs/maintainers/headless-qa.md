# Headless feature qualification

Use the existing suites together: Flutter tests exercise application state and
rendered widgets; Chromium tests exercise real reader engines; native tests
exercise compiled runtimes. A passing widget test does not establish native
playback, hardware HDR/FEL output, NPU performance, or a provider account flow.

Use an isolated worktree for long suites so fixes in `main` cannot change a
running test's inputs. Record its full source SHA, commands, exit codes and logs
in task scratch. Check the host and available space first. Reuse verified source
and dependency caches; never remove another run's outputs or use another task's
emulator. On the owner's desktop, bound heavy work to two CPUs with `taskset`.

## Application and browser checks

From the isolated checkout, with the locked Flutter SDK:

```bash
flutter pub get --enforce-lockfile --no-example
scripts/run_tests.sh --no-pub -j 2 --timeout=120s --machine > "$QA_ROOT/flutter.jsonl"
bash scripts/ci_guard_checks.sh
flutter test --no-pub -j 2 --dart-define=PLEZY_TIZEN=true \
  test/utils/tizen_platform_test.dart \
  test/services/tizen_plex_playback_test.dart \
  test/games/game_catalog_screen_test.dart
flutter test --no-pub -j 2 --dart-define=PLEZY_WEBOS=true \
  test/games/game_catalog_screen_test.dart
(cd tools/reader-tests && npm ci --ignore-scripts && \
  npm exec -- playwright install chromium && npm test)
(cd server && GOMAXPROCS=2 go test -mod=readonly -race -count=1 ./...)
python3 -m unittest discover -s tools/dv-engine -p 'test_*.py'
PLEZY_WEBOS_TEST_TMP="$QA_ROOT/tmp" \
  python3 -m unittest discover -s tools/webos/tests -p 'test_*.py'
```

Set `QA_ROOT` to an existing task-owned directory and create its `tmp` directory
before running these commands. For browser processes use a short temporary path
(for example a task-owned directory directly under `/tmp`): Chromium's Unix
singleton socket can exceed the platform path limit under deeply nested scratch.
Preserve the browser download cache. The reader harness must use its locked
Playwright browser revision, rather than an arbitrary installed Chromium.

Also run the vendored `shared_preferences_linux`, `shared_preferences_windows`,
`universal_gamepad` and `wakelock_plus` package tests from their package roots.
Wakelock's browser suite uses `--platform chrome --dart-define=WEB_PLUGIN_TESTS=true`.

The default Flutter run deliberately skips TV build flags, the real browser
reader and the real Watch Together relay. Run those explicitly before claiming
coverage. The six Windows/macOS external-app discovery cases require their native
OS; changing the platform flag on Linux does not qualify OS discovery APIs.

For the real relay test, use the Open Watch Party source tag matching the locked
Dart SDK, build `./cmd/owp-relay` **from its `relay/` directory**, then set
`OWP_RELAY_BIN` to that binary and run:

```bash
flutter test --no-pub test/watch_together/watch_together_provider_test.dart \
  --plain-name 'on a real relay'
```

The test starts and stops its own loopback relay; it never uses the public relays.

## Native and actual Android checks

Run `scripts/visualizer/test_native.sh` for both supported C++ standards. Build
`android/app/src/test/cpp` with CMake and run CTest. Prepare the locked Steam
sources with `scripts/games/prepare_steam.py`, build `native/games/steam` with
`PLEZY_STEAM_TESTS=ON`, and run CTest under AddressSanitizer/UndefinedBehaviorSanitizer.
The GStreamer and private Weston/Vulkan tests are additional targets. CPU Vulkan
is explicitly unsupported by the presenter's qualification test; record that as
unavailable rather than removing its hardware check.

Build `packages/plezy_torrent/src` with `PLEZY_TORRENT_TESTS=ON` for a real
loopback peer transfer. Keep its default locked dependencies. Linux's pure
HDR/geometry/render-worker and MPV property contracts can run without a display;
the full application/native build remains a separate check in `ci.yml`.

For real Android UI tests, create a task-owned headless AVD from an installed
image, use an unused emulator port in the documented range, and select its serial
explicitly in **every** ADB/Maestro command. Give a modern Google APIs image at
least 4 GiB RAM and allow boot to complete before installing the app. Do not kill
the shared ADB server or drive an attached physical phone. Use the disposable
Jellyfin fixture in `.maestro/jellyfin-demo`; bind its port to loopback and bound
its CPU/memory. The synthetic account is for this fixture only.

Test shrinking as well as debug behavior. The `minified` build type is
debug-signed and uses release Dart artifacts, its matching engine, and R8 with
production keep rules. Leave it non-debuggable: Flutter registers the release
engine when the build type is created, before the configuration body runs;
changing debuggability there subsequently selects incompatible debug snapshots.
Build its app and test APKs
with `-Pplezy.testBuildType=minified`, then install and invoke instrumentation
only on the owned emulator. For an x64 emulator add
`-Ptarget-platform=android-x64 -Pandroid.injected.build.abi=x86_64` to avoid
compiling unused native ABIs. Resolve the APK from AGP's
`intermediates/apk_ide_redirect_file/.../redirect.txt` and its referenced
`output-metadata.json`: with the injected ABI selector, a previous
`outputs/apk/...` file can remain stale even after a successful new build.
Install these test-only APKs with `adb -s SERIAL install -t -r APK`.
Confirm the packaged AOT `lib/x86_64/libapp.so` exists and the debug
`assets/flutter_assets/kernel_blob.bin` does not. The `android-r8-reachability` target in
`scripts/maestro/run_maestro_ci.py` includes FFmpeg, MPV JNI and ML Kit registrar
checks. ML Kit's test discovers names from merged manifest metadata and invokes
their constructors without directly linking those classes from the harness. It
also boots the Flutter activity so a native-only green result cannot conceal an
engine/snapshot mismatch. This test uses Java framework APIs: Kotlin helpers used
only by instrumentation can legitimately be absent from the shrunk app.
Keep harness dependencies and separately invoked optimized entry points only in
`proguard-instrumentation-rules.pro`, which is excluded from shipped variants.
Pass all production constructor arguments in native tests rather than relying
on a default-argument bridge that production shrinking can remove.

Run the baseline and controlled offline scenario through the same entry point
used by `run_maestro_ci.py`. Set `QA_SERIAL` to the owned emulator,
`QA_APK` to the verified APK, and `QA_JELLYFIN_PORT` to an unused loopback port
whose following port is also free:

```bash
python3 scripts/maestro/run_maestro.py basic --device "$QA_SERIAL" \
  --apk "$QA_APK" --skip-build --adb-reverse \
  --jellyfin-port "$QA_JELLYFIN_PORT" --diagnostics-dir "$QA_ROOT/basic"
python3 scripts/maestro/run_maestro.py basic --device "$QA_SERIAL" \
  --apk "$QA_APK" --skip-build --adb-reverse \
  --jellyfin-port "$QA_JELLYFIN_PORT" --fault offline \
  --flow .maestro/flows/09_download_offline_playback.yaml \
  --diagnostics-dir "$QA_ROOT/offline"
```

The baseline excludes the `fault-offline` tag; the existing dedicated CI recipe
runs that scenario with its control URL. Selecting the offline file without
`--fault offline` fails before building. Artifacts from successful and failed
flows go into the requested diagnostics directory. Keep the actual HTTP consent
dialog enabled and accept it only for the disposable fixture. Search uses its
submit action to finish editing; avoid racing `hideKeyboard` against a keyboard
being restored after navigation. Playback exits with one Back press. Long
service pages require scrolling to their rows before asserting visibility.

Retain test receipts, failure logs and screenshots. After all consumers exit,
remove the owned emulator, fixture containers/volumes, worktrees and temporary
build outputs. Preserve shared dependency caches and report retained artifacts.

## Qualification record: 2026-11-07

The full Flutter baseline is `5461085d8dbae620593148a12efb99faed9472ed`.
Initial artifact inspection used published 3.0.3 source
`63f6d4ca42bf874d412708920257a7c9be1ec8c8`. Final Android checks use a clean
minified build of main `179d8c81ad26286f00728c3fa3059f950330796e`, with all
application fixes, debug signing and the test-only harness rules described above.

| Check | Result |
| --- | --- |
| Full Flutter suite | 9,786 passed, 14 environment-specific skips, 864 suites |
| Real Chromium EPUB/comic/RTL reader | 3 passed |
| Tizen / webOS build-flag acceptance | 4 / 1 passed after fixing the translation wrapper |
| Real local Watch Together relay | 1 passed |
| Server Go race checks | Two packages passed |
| Guard Python regressions | 880 passed, plus static checks |
| Maestro runner regressions | 24 passed |
| Dolby Vision tools / webOS tooling | 109 / 57 passed |
| Steam native ASan/UBSan / GStreamer | 41 / 1 passed |
| Linux playback/HDR contracts under ASan/UBSan | 6 passed |
| Android host-native contracts | 2 passed |
| Android JVM | 719 passed across 67 suites |
| Minified Android FFmpeg/MPV/ML Kit and activity boot | 5 passed |
| Complete Android baseline through the CI entry point | 8/8 passed in 4m 32s |
| Controlled download/offline playback | Passed while the server proxy denied requests |
| Independent native edge Back gesture | Passed |
| Phone library regression and related widgets | 34 passed; targeted analysis clean |
| Source database, remote streams and profile teardown | 241 passed, three browser-specific skips |
| Focus/navigation, overlay sheets and profile sessions | 185 passed |
| Media-detail widgets | 69 passed |
| Visualizer lifecycle | Five checks passed in each of C++17 and C++20 |
| Published visualizer pixels on software EGL | Two presets × 12 changing frames in each of OpenGL and OpenGL ES |
| Torrent runtime | Verified loopback transfer passed |
| Vendored plugin VM checks | 68 passed |
| Browser wakelock | 13 passed |

The runtime pass found ML Kit registration broken in the published Android APK:
its manifest-named registrar classes survived shrinking, but their constructors
did not. SDK DEX inspection and actual device logs agree. The fix preserves only
the ML Kit registrar classes and constructors, following the discovery contract
also expressed in [Firebase's consumer rules](https://github.com/firebase/firebase-android-sdk/blob/main/firebase-components/proguard.txt).

Other repaired blockers were the Steam timer callback's direct-call type,
Maestro's obsolete app IDs, the fixture image's missing HTTP helper and unwritable
seed configuration, and a missing translation provider in the TV games harness.
Actual phone testing additionally exposed a library toolbar that displaced its
picker; the fix preserves the actions in an overflow menu and has a regression
that fails on the old layout. The subtitle size-boundary tests now use explicit
best compression so a JDK's default compression choice cannot invalidate the
fixture; the size and ratio assertions remain intact.
Concurrent real SQLite connections also reproduced a first-open lock/migration
race affecting logout. Factory opens now wait for complete schema initialization
before another connection opens, while each consumer retains independent close
ownership. Regression tests cover concurrent access, connection teardown and
recovery after a failed open.
The repaired minified Android app also passed the real fixture logout flow,
returning to both sign-in choices after fresh onboarding.
After IME use on Android API 36, a single Back key also delivered a native
system-pop callback between its handled down/up events. This closed two profile
or settings routes. The input tracker now consumes that duplicate only while an
app-owned physical Back key is held. Tests reproduce the original failure and
preserve independent gestures and declined root/exit presses, including recovery
from an earlier lost release. This uses event ownership, without a timed debounce.
The phone media-detail overflow control now has a localized accessible name;
Download remains available in its menu when the toolbar compacts.
Logs and machine-readable receipts are retained in the task's qualification output.

The visualizer runtime was extracted from the SHA-256-verified published Linux
AppImage. Linux packaging strips ELF libraries after installation, so its build
receipt records producer bytes before that transformation; retain the final
packaged library digest separately rather than comparing it to the pre-strip hash.
