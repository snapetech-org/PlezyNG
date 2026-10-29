# Steam SDK preparation and build-agent handoff

Use the current head of [PR #81](https://github.com/snapetech-org/PlezyNG/pull/81),
branch `codex/steam-vulkan-cloud-relay-20261028`. Record the exact commit before
starting. This handoff prepares real platform SDKs and builds the implemented
receiver. It does not certify a signed app, physical HDR output or a live Steam
account/service. Continue with [LIVE_TEST_HANDOFF.md](LIVE_TEST_HANDOFF.md) after
the relevant app build passes.

Controller-only phone mode was added after the previously recorded
42-export Android build. Its new JNI connection query and input-only negotiation
need an exact-head Android build, followed by iOS SDK compilation and paired-host
acceptance. Do not treat the earlier export count as validation of this follow-up.


All Actions jobs remain on compatible private ephemeral JIT runners. Provision
only an idle, isolated build agent; preserve active builds and existing SDKs.
Missing private capacity is a provisioning blocker. No hosted fallback, runner
trust widening, publishing, account mutation or deployment is part of SDK setup.

## What is ready

| Platform | Preparation and build code | Evidence from this development environment |
| --- | --- | --- |
| Android / Android TV / Fire TV | Verified CLI bootstrap for Linux x64, macOS Intel/ARM and Windows; all root/vendored module SDK pins; serialized installs; real NDK builder and ELF/JNI inspection | CLI 22.0, JDK 21, API 34/35/36/37.0, build tools 36.1.0, NDK 29.0.14206865 and CMake 3.22.1/4.1.2 installed. Release JNI libraries compile/link for ARM64, ARMv7, x86 and x86_64. All 42 JNI exports checked per ABI. Both 64-bit ELFs have 16 KB LOAD alignment. Controller Kotlin/Java and the Flutter Steam adapter compile against real SDK/Flutter APIs. |
| Linux / SteamOS | Development/runtime preflight, Ubuntu/Debian package list, codec-element checks and JSON receipt; native-test and packaging prerequisites wired into CI | GTK 3.24.41, libsecret 0.21.4, libevdev 1.13.1, Wayland 1.22.0, EGL 1.5, GStreamer 1.24.2 and Vulkan 1.3.275 preflight passes, including all required codec/test elements. |
| Windows x64 / ARM64 | Official checksum-pinned VS bootstrapper and `.vsconfig`; signature validation; separate-instance provisioning; compiler, SDK headers/libraries, CRT, resource tools and CMake checks | Bootstrapper downloaded and SHA-256 verified. PowerShell parsing and unsupported-host refusal pass. Actual Windows installation, Authenticode validation and MSVC app builds require Windows agents. |
| macOS / iOS / iPadOS / tvOS | Process-local Xcode selection, exact-build assertion, Metal preparation, five SDK/architecture targets, actual ObjC++/Swift/Metal probes and existing native archive builder | Preparation/error/availability-target tests pass. No Apple SDK is present on this Linux host; real SDK probes, Xcode builds and signing require Mac agents. |

There are **39 passing Python SDK/source-preparation tests** (14 shared Android
SDK tests and 25 Games preparation/archive/artifact tests). Workflow action-pin,
architecture/private-runner and security checks pass. The amended workflows have
not been dispatched from this environment; their execution is a build-agent gate.

SDK archives and generated binaries are intentionally outside source control.
Locks, recipes, probes, tests and handoff instructions are committed. See
[VALIDATION.md](VALIDATION.md) for build evidence and artifact hashes.

## Shared inputs and reporting

- Use the repo's Flutter **3.47.1**, locked Dart/native dependencies and JDK **21**
  on Android. Python **3.10+** is required by the preparation scripts. Keep the
  existing application minimum OS versions and optional receiver defaults.
- Resolve Dart dependencies with `flutter pub get --enforce-lockfile --no-example`.
  tvOS uses `tvos/scripts/pub_get.sh` and its pinned engine flow instead.
- `games-native.lock.json` and `scripts/games/prepare_steam.py` supply the pinned
  transport, Opus, crypto, Pyrowave and Granite sources. The receiver does not
  require downloading a publisher's proprietary Steamworks SDK or credentials.
  Game-side Steam APIs and Valve-approved Cloud grants remain separate contracts.
- Treat exit status and JSON `status` together. A successful SDK receipt is not
  a successful application build. Receipts include commit/dirty state and actual
  SDK versions; Android artifacts also include SHA-256 and JNI checks. Never
  promote a receipt from a different commit or a dirty checkout without review.
- Keep compiler logs, SDK receipts, full app test results and artifact checksums
  together. Secrets, PINs, access tokens and signing identities do not belong in
  these receipts. Use the existing platform signing/release process only after
  unsigned builds and live acceptance pass.

## Android agent

Install JDK 21 on the private builder and select it using `JAVA_HOME`. Set
`ANDROID_SDK_ROOT` to an absolute, agent-owned directory; `ANDROID_HOME` should
identify that same directory when configuring Gradle. No global Java/SDK setting
is changed by the Python installer.

```sh
python3 scripts/prepare_android_sdk.py bootstrap
python3 scripts/prepare_android_sdk.py install
python3 scripts/prepare_android_sdk.py verify
python3 scripts/games/build_steam_android.py --report build/receipts/steam-android.json
```

`bootstrap --archive /absolute/path/commandlinetools-….zip` supports an offline
copy only when it matches the checked-in host-specific SHA-256. The pinned CLI
is installed side by side, preserving `cmdline-tools/latest`. Windows uses
`python` and the same script; `.bat`, `.cmd` and `.exe` SDK paths are supported.
Windows ARM hosts use Google's x64 host tools through Windows compatibility;
the selected application ABI is independent of the host-tool architecture.

`install` accepts Android SDK licenses and installs exact versions discovered
from both `android/` and `packages/*/android/`. CI must configure the private
download proxy first with the existing `proxy` action. Local builders can use
their ordinary network configuration. SDK modifications are serialized with an
OS lock. Broken legacy nested platform archives are repaired only after API and
package-identity validation; the previous container is preserved outside SDK
discovery. Working platform directories are not overwritten by this repair.

The native builder defaults to all four ABIs. Repeat `--abi arm64-v8a` and
`--abi armeabi-v7a` for a targeted run. It builds the actual JNI/Vulkan/Pyrowave
receiver, verifies all declared Java native exports, rejects text relocations
and runtime search paths, and checks 16 KB alignment on 64-bit outputs.
`--inspect-only --build-dir /absolute/path` inspects existing
`<directory>/<abi>/libplezy_steam.so` files and explicitly records that no new
build was invoked.

For the full application, use the existing `android-engine` job in
`.github/workflows/games-native.yml` and Android release configuration. The job
configures Flutter/SDK paths, builds both embedded engines and the real app,
runs Steam JVM tests, then builds/inspects the release JNI artifacts. In an
equivalently provisioned checkout, the module commands are:

```sh
cd android
./gradlew :moonlight:assembleDebug :steam:assembleDebug :steam:testDebugUnitTest :app:assembleDebug --stacktrace
./gradlew :app:assembleRelease --stacktrace
./gradlew :app:assembleDebug -PplezyGamesEmbedded=false --stacktrace
```

Use `gradlew.bat` on Windows. Follow the repository's existing release-signing
configuration; no new signing keys are introduced here. Require Kotlin/Java,
manifest/resources, AAR/JNI packaging, R8 and the full app to pass. Check both
shipped ARM ABIs, emulator ABIs where packaged, and the embedded-disabled build.
Verify the final APK/AAB's native-library alignment as well as the standalone ELF.

## Windows agents

Run PowerShell 7.2+ on the native x64 and ARM64 private agents. Existing
`windows/tool/prepare-build-toolchain.ps1` remains responsible for the app's
other pinned build utilities. The Steam preflight is read-only by default:

```powershell
.\windows\tool\prepare-steam-sdk.ps1 -Architectures x64 -Report build/receipts/steam-windows-x64.json
# On the ARM64 agent:
.\windows\tool\prepare-steam-sdk.ps1 -Architectures arm64 -Report build/receipts/steam-windows-arm64.json
```

For a fresh idle image without the SDK, explicitly provision a new separate
instance. Choose an unused absolute path; the installer refuses an existing
Visual Studio directory rather than modifying a discovered instance.

```powershell
.\windows\tool\prepare-steam-sdk.ps1 -Install -InstallRoot D:\PlezySdk `
  -Report build/receipts/steam-windows-install.json
```

The installer verifies the official bootstrapper's SHA-256 and valid Microsoft
Authenticode signer before execution. It requests VS 2022 C++ x64/ARM64 tools,
CMake and Windows SDK 10.0.26100.0. A required reboot is reported without rebooting
the agent automatically. Bootstrapper bytes and the SDK generation are pinned;
Visual Studio services its compiler components, so record the actual MSVC/VS
versions from the receipt rather than claiming an immutable package catalog.

Run the existing `windows-native-test` CI matrix for both architectures. It
checks this SDK, installs the pinned Flutter engine, compiles the real app and
vendored SDL3 controller plugin, and executes native tests on Windows. A MinGW
link or a file-presence preflight does not replace MSVC or Windows execution.
For standalone transport diagnostics, use the receipt's CMake/VS instance:

```powershell
python scripts/games/prepare_steam.py
$sdk = Get-Content build/receipts/steam-windows-x64.json -Raw | ConvertFrom-Json
& $sdk.cmake -S native/games/steam -B build/steam-msvc-x64 -G 'Visual Studio 17 2022' -A x64 `
  "-DCMAKE_GENERATOR_INSTANCE=$($sdk.visualStudioPath)" "-DCMAKE_SYSTEM_VERSION=$($sdk.windowsSdk)" `
  -DPLEZY_STEAM_TESTS=ON
if ($LASTEXITCODE) { throw 'Steam MSVC configuration failed' }
& $sdk.cmake --build build/steam-msvc-x64 --config Debug --parallel 2
if ($LASTEXITCODE) { throw 'Steam MSVC build failed' }
ctest --test-dir build/steam-msvc-x64 -C Debug --output-on-failure
if ($LASTEXITCODE) { throw 'Steam Windows tests failed' }
```

Use the ARM64 receipt, a separate directory and `-A ARM64` on the ARM64 agent.
Inspect Media Foundation/HEVC availability and HDR/controller/audio behavior
only after full app builds succeed.

## Apple agents

Install the approved **full Xcode** from
[Apple's developer downloads](https://developer.apple.com/download/all/) or the
App Store on a Mac. Apple's standalone Command Line Tools do not supply iOS/tvOS
SDKs. This repository does not fetch unofficial SDK mirrors or represent Linux
header substitutes as an Apple build. Full Xcode acquisition/Apple license setup
is an image-provisioning prerequisite; the script prepares that installation.

Select Xcode only for the current process. Record its build identifier with
`xcodebuild -version`; pass the image's approved identifier using
`--require-xcode-build` when a specific image is required.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/games/prepare_apple_sdk.py prepare --sdk macosx --arch arm64 --report build/receipts/apple-setup.json
for sdk in macosx iphoneos iphonesimulator appletvos appletvsimulator; do
  python3 scripts/games/prepare_apple_sdk.py probe --sdk "$sdk" --arch arm64 --report "build/receipts/apple-$sdk.json"
done
python3 scripts/games/prepare_apple_sdk.py probe --sdk macosx --arch x86_64 --report build/receipts/apple-macos-intel.json
```

`--developer-dir /Applications/ApprovedXcode.app` is an alternative to the
environment variable. No `xcode-select --switch` is performed. Preparation checks
the requested Xcode build before changing components, runs first-launch setup,
uses bundled Metal when it works and downloads Apple's Metal component only
when needed. `--simulator-version <approved-exact-version>` with a simulator SDK
optionally downloads that simulator runtime. A runtime is distinct from the SDK
and does not install full Xcode.

Preflight validates the selected Xcode project with `plutil`. The probes compile
actual VideoToolbox/Pyrowave receiver code, microphone
availability guards, controller Swift and the actual embedded conversion/HDR
presentation shaders through the Metal compiler and linker. They preserve
macOS 14.0, iOS 15.5 and tvOS 15.0 deployment targets. `--flutter-framework` accepts
the matching `Flutter.framework` or `FlutterMacOS.framework` directory to compile
the complete adapter too; without it the receipt explicitly says that adapter
was not checked. Device and simulator frameworks must not be interchanged.

Build native archives for all device SDKs and both macOS architectures:

```sh
PLATFORM_NAME=macosx ARCHS='arm64 x86_64' DERIVED_FILE_DIR="$PWD/build/steam-apple/macos" python3 scripts/games/build_steam_apple.py
for sdk in iphoneos iphonesimulator appletvos appletvsimulator; do
  PLATFORM_NAME="$sdk" ARCHS=arm64 DERIVED_FILE_DIR="$PWD/build/steam-apple/$sdk" python3 scripts/games/build_steam_apple.py
done
```

The archive builder includes transitive crypto archives and verifies architecture
slices before replacing its final archive. Then build the actual Runner
workspaces and their native tests. The `apple-native-test` CI matrix now prepares
Metal, probes actual sources and preserves receipts before its existing Flutter,
locked CocoaPods/SPM and Xcode test steps. It covers macOS plus iOS/tvOS simulators.
Use the same locked dependency preparation for **device SDK** builds as well:

```sh
xcodebuild build -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO
xcodebuild build -workspace tvos/Runner.xcworkspace -scheme Runner -configuration Release -sdk appletvos -destination 'generic/platform=tvOS' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO
```

For tvOS, retain `tvos/scripts/pub_get.sh`, `fetch_engine.sh`, `pod_install.sh` and
the project-wiring tests from the workflow. For iOS/macOS, retain the committed
Podfile locks and `scripts/refresh_apple_spm.sh` flow. Signed device archives are a
separate gate. Simulator Metal skips are recorded as skips, never HDR proof.

## Linux agents

On a fresh Ubuntu/Debian private image, print the receiver prerequisite list:

```sh
python3 scripts/games/check_linux_sdk.py --apt-packages
```

Install those distribution packages using the agent's normal image-provisioning
process, plus the app's existing libmpv/packaging dependencies. The existing
Linux CI jobs now include the missing codec tools/plugins, Vulkan development
files and Jinja2. The preflight does not mutate the machine.

```sh
python3 scripts/games/check_linux_sdk.py --report build/receipts/steam-linux.json
python3 scripts/games/prepare_steam.py
cmake -S native/games/steam -B build/steam-linux -G Ninja -DCMAKE_BUILD_TYPE=Debug -DPLEZY_STEAM_TESTS=ON -DPLEZY_STEAM_GSTREAMER=ON
cmake --build build/steam-linux --parallel 2
ctest --test-dir build/steam-linux --output-on-failure
```

Run the real Linux Runner and package jobs on x64/ARM64 where supported by the
existing matrix. Preserve both Wayland direct-GPU and X11 SDR behavior. Check
the final package's GStreamer runtime/codec dependencies; a developer machine's
installed plugins do not prove they are available on a clean user's machine.

## Acceptance before device handoff

Require the intended commit, a clean checkout, successful platform preflight,
successful full app build/tests and artifact checksum for every assigned target.
Capture actual compiler/SDK versions, architecture, deployment minimum and any
skipped tests. Repeat the build with embedded games disabled on supported
configurations. Run [LIVE_TEST_HANDOFF.md](LIVE_TEST_HANDOFF.md) for real hosts,
controllers, audio/microphone, HDR/chroma, accessibility and internet routing.
Valve authority, Families live compatibility and relay deployment remain
explicit service qualification; SDK installation cannot grant those capabilities.

Official setup references: [Android tools/checksums](https://developer.android.com/studio#command-line-tools-only),
[sdkmanager](https://developer.android.com/tools/sdkmanager),
[Apple additional components](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components),
[Visual Studio installer parameters](https://learn.microsoft.com/en-us/visualstudio/install/use-command-line-parameters-to-install-visual-studio?view=visualstudio),
[Visual Studio component IDs](https://learn.microsoft.com/en-us/visualstudio/install/workload-component-id-vs-build-tools?view=visualstudio).
