# One-command Pleazyng 3.0.1 release

## Current native dependency

Every new application build must use the latest verified
`snapetech-org/mpv-build/main` revision. Refresh all native pin sites with
`python3 scripts/sync_native_revision.py` before validation. This clones the
fork's current main, verifies the content keys for Apple, Android, Linux and
Windows, then invokes the existing atomic capability-receipt pin writer.
Missing native publications fail without changing application pins; use the
release driver below to build or recover the missing native groups first.

The release workflow's initial gate and the local release driver's preflight
run `python3 scripts/sync_native_revision.py --check`. A stale revision or a
different producer repository stops the build before platform compilation.
This also applies when reusing an immutable release tag: if its native pin is
stale, advance the application version rather than moving the tag. A build
already in flight retains its exact validated native pin; future builds check
the live producer again. Published releases retain their original provenance.

## Release procedure

After exact-main CI and platform canaries pass, run the complete 3.0.1 release
from an authenticated `gh` session. Compatible Linux, Android, Tizen, Windows
x64, and native Windows ARM64 jobs use standard GitHub-hosted runners. Apple
builds and the storage-heavy WebOS candidate use compatible private JIT runners.
The hybrid execution profile routes each job to the compatible runner class;
the broker pool remains available for jobs that need private capacity.

## Release job concurrency

CI's Android, Linux native and server checks own their checkouts and setup and
consume no artifacts from the other suites. They start independently rather
than waiting for the application tests or for one another. The release gate
still requires all 13 CI jobs to pass on its exact source revision.

`validate-trusted-ref` is the short gate all build jobs wait for. Once it passes,
the independent platform jobs in one `build.yml` release run are eligible to run
in parallel; they do not wait for one another. `package-windows` waits for the
Windows build that produces its input, and `create-release` waits for all
required platform outputs before assembling the draft. The steps inside each
job still run in order.

Capacity determines which eligible jobs start. The hybrid Linux, Android,
Tizen, and Windows jobs can occupy separate hosted runners concurrently. iOS,
tvOS, and macOS use the single private Apple JIT slot, so those three jobs run
one at a time. WebOS uses its own private Linux route and can remain queued
until that compatible capacity is available; it has no dependency on an Apple
job. The stage-by-stage waits in `release_all_platforms.py` protect the exact
native-manifest, CI, tag, and release checks; they do not serialize
independent platform jobs inside the dispatched release workflow.

For Apple queue inspection and the one-job JIT launcher, see the
[Apple JIT runner runbook](apple-jit-runner.md).
Each ephemeral launcher holds its own `caffeinate -i -w` idle-sleep assertion.
The assertion follows the launcher PID through runner startup and ends when that
one-job process exits, so active builds no longer depend on a manually timed
awake command.

Hybrid CI runs Linux AddressSanitizer and ThreadSanitizer on separate hosted
machines concurrently. The one-job matrix limit remains for the private profile;
Apple jobs serialize independently because they share one physical Mac.

Hosted Ubuntu images may route APT through `mirror+file:` entries. Editing only
`sources.list` or `ubuntu.sources` leaves `/etc/apt/apt-mirrors*.txt` pointing at
the slow Azure HTTP mirror. CI and release jobs run
`scripts/configure_hosted_apt.py` with GitHub's `runner.environment` context before
package installation or the APT cache action. It handles all three source forms,
selects the official ports archive for ARM64 and adds network retries/timeouts.
It returns before reading or changing any private runner's APT configuration.

The macOS app combines Rust, LuaJIT, Objective-C and C++ exception handlers.
Apple's compact-unwind format cannot encode all four personalities in one
image. The `Isolate LuaJIT runtime` phase repackages SwiftPM's checksum-verified
LuaJIT archive as `libplezy_luajit.dylib`, links it before the original static
framework, and embeds/signs it with the application. It retains ordinary unwind
metadata and the production native pins. The packaged
`playback-notices/luajit-runtime.json` records input/output hashes, architectures,
deployment target and the build command. Do not replace this with flags that
disable unwind metadata: linking alone does not prove exception recovery.

Release signing handles bare Mach-O helpers in both `Contents/MacOS` and
`Contents/Frameworks` before sealing nested frameworks/XPC bundles. Preserve
existing nested entitlements, then run
`scripts/apple/finalize_macos_runtime_receipts.py` after the final library signing
and before signing the app. The receipt retains its build-stage digest separately
from the final embedded digest; later signing must not silently stale it.

Release actions reuse an existing immutable version tag. If the tag is an
ancestor of `main`, the workflow permits only release infrastructure, changelog,
maintainer documentation, and the WebOS compatibility lock to differ from the
tagged commit; application-source changes still require a new matching tag.
Both the workflow and the local release driver enforce this allowlist, and the
draft release remains tied to the existing tag.

```sh
python3 scripts/release_all_platforms.py --version 3.0.1 \
  --execution-profile hybrid --publish-github-only \
  --include-webos-release \
  --ffmpeg-source-cache /mnt/disks/scratch/task-scratch/plezyng-release-3.0.1-20261103/ffmpeg-preflight \
  --scratch /mnt/disks/scratch/task-scratch/plezyng-release-3.0.1-20261103/release-final
```

The core command builds every required platform, verifies its artifacts and
checksums, then publishes GitHub. It records that success before attempting
Discord or configured distribution channels. Delivery failures remain in the
summary for separate repair/retry against the immutable release; they do not
turn publication into a failed core build. WinGet and Chocolatey metadata are
attached when produced, while installers and all required Linux formats remain
mandatory. See [channel retries](release-channel-retries.md).

Use explicit signing and Homebrew qualification options separately when those
preparations are requested. They require signed iOS/tvOS archives and a
notarized macOS Cask candidate, even for GitHub-only publication. They do not
enable store uploads or tap publication. Successful-run reuse checks the requested
signing, notarization and Cask steps; asset validation requires both signed IPAs
and `snapetech-pleazyng.rb`. These options default off and require a full build;
they cannot be combined with platform-artifact recovery.

The command validates CI on the exact current `main` SHA, then runs the complete
release build. When a version tag already exists, it reuses that immutable tag
only if it is an ancestor of `main` and the intervening changes are on the
release allowlist; the release workflow builds the full platform matrix. For a
new version, it first verifies or refreshes native artifacts, updates their
pins, validates all 13 CI jobs, creates the immutable tag, and builds the complete
release matrix once. Publication waits for every platform and artifact check.
If a product fix is needed after tagging, advance the patch version and build
number; never move a tag or replace an already published release.

If the control-plane host cannot reach `ffmpeg.org`, pass
`--ffmpeg-source-cache <directory>` with retained files named
`ffmpeg-<pinned-version>.tar.xz`, `ffmpeg-<pinned-version>.tar.xz.asc`, and
`ffmpeg-devel.asc`. The orchestrator copies those files into the new scratch
directory and still requires a valid signature from its pinned FFmpeg release
key before it records a checksum or changes Pleazyng's pins.

When a completed native run has failed platforms, the orchestrator can recover
other groups whose publishing jobs succeeded. It checks the manifest artifact's
GitHub digest, the current source content keys, and every published asset's
checksum before recording that group on native `main`. Only manifests from an
explicit native build of an ancestor of current `main` are eligible. The next
native build then rebuilds only the groups still stale. A partial recovery never
updates Pleazyng's pins or bypasses the final all-platform verification.

`scripts/set_native_revision.sh` also checks Snapetech producer manifests before
changing any of the eleven Apple, application-lock and Android verification pin
sites. Every required Android ABI, Linux/Windows architecture and Apple slice
must have a schema-4 package receipt for ordered PCM and its implemented neural
filters. Linux and Windows receipts must also contain boolean `pmeVulkan: true`,
emitted only after the producer finds the compiled PME Vulkan reconstruction
code marker in the actual binaries. A generic PME filter receipt is insufficient.
Archive checksums, binary hashes and actual machine inventories must
agree. Mixed or missing receipts leave every pin unchanged. Accepted receipts
are retained under `nativePackages` in `mpv-build.lock.json`; they establish
compiled inclusion, while `executionQualified: false` remains valid and does
not claim device playback or display qualification.

Android CI, release, and embedded-engine workflows share
`scripts/prepare_android_sdk.py`. It configures Java and Gradle proxy settings
before SDK setup, reads every checked-in Android module's SDK/NDK/CMake pins,
installs those exact packages, and checks the installed tools. This includes
Steam's CMake 3.22.1 alongside the app/libass CMake 4.1.2. A fresh runner must
not depend on Gradle silently downloading missing toolchains during compilation.

Android CI and release also install `scripts/prepare_gradle_repositories.py`
before Gradle starts. Its init policy adds the Maven Central mirror before
settings plugins resolve, including Flutter's independent included build.
Android's parent `settings.gradle.kts` cannot configure that build by itself.
The CI and release Flutter, pub, and Gradle cache keys must match; the repository
checks enforce this so a green CI run warms the release caches.

Desktop CI stages the pinned MilkRust runtime with
`scripts/visualizer/build_runtime.py` before any Flutter or CMake configuration;
the source receipt remains mandatory, including in native reliability and Linux
package smoke jobs. Apple CI runs locked pub dependency resolution, then
`scripts/refresh_apple_spm.sh`, before Flutter configuration can consult a stale
SwiftPM mirror. The full Flutter application suite belongs to the required Unit
Tests job; code analysis does not repeat it.

Keep all three CocoaPods lockfiles aligned with native pods and resolved Flutter
plugins. CocoaPods records local spec checksums from the JSON it installs under
`Pods/Local Podspecs`, rather than the original Ruby `.podspec` file. Regenerate
through normal pod installation or the CocoaPods sandbox serializer, then verify
`pod install --deployment`; hashing the Ruby source directly gives the wrong lock.

Xcode creates directories declared by build-phase output paths before running
the phase. MilkRust accepts a fresh empty output directory; reusable artifacts
still require an exact, digest-verified receipt. Nonempty outputs without a
valid receipt remain an error.

MilkRust resolves its compiler tools from its isolated pinned Rustup toolchain.
Homebrew's Rustup manager can be installed without global `rustc`/`cargo` shims;
the build must select its own toolchain binaries explicitly.

Hosted Linux sanitizer jobs replace the Azure Ubuntu mirror with the main HTTPS
archive and use bounded network timeouts and retries. Private runner sources and
proxy configuration remain unchanged.

Nested Apple DV builds receive a scoped execution, Git and network environment.
Outer app settings such as `EXECUTABLE_DEBUG_DYLIB_PATH` must not leak into the
runtime's framework graph. The parent environment remains available for app
signing and embedding; verify the embedded non-system framework dependency
closure when changing this build boundary.

Xcode embeds `${EFFECTIVE_PLATFORM_NAME}` in CMake target-file arguments for
embedded SDKs, as described in the
[CMake property documentation](https://cmake.org/cmake/help/latest/prop_gbl/XCODE_EMIT_EFFECTIVE_PLATFORM_NAME.html).
The RomM source packager resolves that one placeholder from the active Xcode
phase environment, retaining separate device/simulator paths and strict checks
that every built core, source archive, licence and checksum exists. Do not work
around this by dropping a core or disabling its notices target.

The dependency job also verifies the current public release ledger live. A
documented absence requires a missing latest/tag response and a successful
authenticated release list; authentication, network and server errors still
fail the job. After publishing, update the ledger and README from the actual
GitHub release metadata rather than leaving the prior absence claim in place.

For a transient dependency-download failure, preserve the failed job log and
let other platform jobs finish. Once the workflow is completed, retry that job
and its dependents with `gh run rerun RUN_ID --job JOB_ID`. After the targeted
retry succeeds, invoke the release driver with fresh scratch; it reuses the
successful CI and release run before validating and publishing the assets.
Avoid redispatching the full platform matrix for a download-only failure.

Windows CI and release jobs provision NuGet from `windows/tool/build-toolchain.lock.json`
before Flutter configures its plugins. The installer job also provisions Inno Setup
from that lock; both downloads require matching hashes and publisher signatures.
`-VerifyOnly` checks the installed tools before compilation or packaging. The
3.0.1 hybrid profile uses `windows-2025` for x64 and the native
`windows-11-vs2026-arm`
runner for ARM64; ARM64 is packaged as a separate portable ZIP while installers
and package-manager artifacts remain x64. Linux ARM64 uses `ubuntu-24.04-arm`.
The Mac remains reserved for Apple work. See
[the Windows toolchain runbook](../../windows/tool/build-toolchain.md).

Apple JIT source workspaces use `/Volumes/p/runs/...`, a short mount alias of
the same kspld0 NFS export that is also mounted at
`/Volumes/plezyng-native-build-kspld0`. The Dart macOS native-asset step rewrites
dylib install names to absolute workspace paths; the longer mount path exceeded
the bundled SMB library's Mach-O header padding. The JIT account cannot mount
shares itself, so the Mac host must provide `/Volumes/p` before dispatch. The mount uses the stable Headscale path `kspld0.tail.snape.local` and client identity `100.64.0.3`; its LaunchDaemon reconnects the existing Tailscale identity and retries every 60 seconds if Tailscale is not ready at startup. The Apple
scratch preflight checks that `/p` is the expected NFS export and fails before
checkout or build work if it is absent. Xcode build products remain on local
APFS; only the task-scoped source workspace and scratch data use NFS. Keep the
existing long mount for the Mac-backed Linux ARM64 worker and leave both mounts
in place while any Mac job owns the shared slot. The Apple Steam-source hook
also removes AppleDouble files after its pinned source checkout, since that
checkout is generated during the Xcode build after the initial workspace copy.

Release-channel workflows set `GH_REPO` before checkout, so their release gates
and downloads do not depend on a previous workspace. The runner bootstrap installs
native gem compilation and distribution package tools before accepting publication
jobs; Fastlane, COPR and PPA jobs verify them without sudo before use. Relay container publication
passes the private proxy into both the BuildKit daemon and Docker's predefined
proxy build arguments; the Dockerfile does not persist those settings in the
runtime image. See [Docker's proxy arguments](https://docs.docker.com/build/building/variables/#proxy-arguments).

Snap packaging uses Canonical's digest-pinned multi-platform core24 OCI image
from `linux/packaging/snap/toolchain.lock.json`. Trusted-main hybrid builds may
run on hosted Linux with direct networking explicitly enabled by the release
workflow; private JIT runs use the restricted proxy. Both use Podman without a
nested LXD build or a snapd daemon. `scripts/build_snap.sh` rejects an
architecture mismatch, verifies the image architecture and completed SquashFS,
and removes its own container after completion or failure. The container
supplies Ubuntu 24.04 regardless of the runner distribution; only the job's
packaging directory is mounted into it. See [Canonical's Snapcraft images](https://github.com/canonical/snapcraft-rocks).

After native artifacts verify, the command verifies the FFmpeg source archive
signature against FFmpeg's pinned release-key fingerprint, records its exact
SHA-256 in the Android header build, and runs
`scripts/set_native_revision.sh` for the published artifact-manifest commit.
It pushes that focused pin update to Pleazyng `main`, waits for CI on that exact
commit, creates its immutable `v<version>` tag, and dispatches one complete
`action=release`, `mode=release` build. Verified native components are reused
by content key and published digest; a second native or application build is
not required merely to rename a candidate. All versioned builds require
Android, Linux x64/ARM64, Windows x64/ARM64, universal macOS, iOS, tvOS, Tizen,
and webOS. The webOS IPK, its actual app-source provenance, engine provenance,
compatibility record, and checksums enter the release with the other platforms.
Device qualification remains descriptive and does not gate inclusion of an
implemented feature or platform. Apple jobs refresh their SwiftPM mirror after
the native pin changes.
Before publication, the orchestrator checks that every required release asset
exists. `--publish-github-only` promotes the verified GitHub draft and starts
its automatic Discord announcement without dispatching store, package,
container, or appcast workflows.
`--publish` promotes the draft and sequentially dispatches configured channels.
It
reuses successful channel runs and stops on a prior failed run rather than
repeating an external side effect blindly.

WebOS uses private Linux capacity for its large SDK. Its runtime inputs remain
hash-locked and package inspection verifies ARM ELF files, application ID,
version, permissions, licenses, and runtime hashes. `check_release_package.py`
then checks the new package against its recorded source and SHA-256. Historical
C6 evidence is not an approval lock on an older application commit. Do not
report device playback, vendor permission, or store approval as established by
a build. The generated LG handoff is for manual review, not store publication.

Tizen remains a tester artifact for qualification; Seller Office signing and
submission are not configured. App Store Connect and Amazon uploads do not
submit builds for review. Google Play is sent to the internal draft track.
Microsoft Store, Samsung Seller Office, macOS Developer ID signing, Windows
Authenticode signing, and vendor-store publication require their configured
identities, profiles, and credentials. These store channels do not gate the
complete GitHub release.

The orchestrator uses the current machine's GitHub CLI authentication only for
workflow dispatch, repository commits, and the version tag. Its default hybrid
profile sends compatible jobs to GitHub-hosted runners and uses private JIT for
Apple, storage-heavy WebOS, and other private-resource work. The script does not
accept custom runner labels or store or print credentials.
It stops on a failed native group, FFmpeg signature, CI run,
tag conflict, or release build. Re-running it reuses successful native,
CI and release runs and never moves an existing tag.

If Android fails, merge the infrastructure fixes, then recover the
native run without rebuilding its entire matrix. Android and WebOS recovery may start while native
jobs are still running; release assembly waits for their successful completion:

```sh
python3 scripts/release_all_platforms.py --version 3.0.1 \
  --execution-profile hybrid --publish-github-only \
  --reuse-platform-run SOURCE_RUN_ID --scratch /path/to/empty/task-scratch
```

Recovery requires successful Tizen, Linux, Apple, and both Windows builds
and packaging in a completed trusted-main release run. Its exact source commit
must have all 13 required CI jobs green. A strict file allowlist rejects changes
to application sources, dependencies, or native toolchain inputs between that
run and main. Android and WebOS rebuild on main with their infrastructure fixes. Every
reused artifact's GitHub SHA-256 digest and source identity are checked before
extraction. The release includes `platform-reuse-provenance.json` and its checksum
with the actual source run, CI run, commit, jobs, and artifact digests. Skipped
jobs remain skipped in the recovery run; they are not reported as new builds.
Recovery does not enable App Store signing or Homebrew notarization. WebOS is
rebuilt and included with verified source provenance. If a reused platform fails or product inputs change, fix and
validate that platform instead of broadening the recovery allowlist.

If Android has already succeeded in a separate trusted-main release run, add
`--reuse-android-run ANDROID_RUN_ID`. Its successful job, product input diff,
artifact identity and digest are checked independently and included in the
public provenance. WebOS and Tizen cannot be excluded from a complete versioned
release. Product-source changes require the next patch version and new builds.
An assembly-only recovery waits locally for its source jobs before dispatching,
so a hosted assembly runner does not sit idle while Apple builds finish.

The final JSON receipt is written to the printed scratch directory. Temporary
checkouts and the verified source archive are removed after the workflow run;
GitHub retains the workflow logs and release artifacts. The scratch directory
and its receipt remain for review and should be cleaned only after the release
has completed and its outputs have been transferred or retained deliberately.

### Linux speech and neural runtime

Ordinary Linux builds select the locked `sherpa_onnx_linux` ONNX Runtime for
both speech and motion processing before CMake installs the bundle. PME still
compiles against the pinned API-v27 SDK. This avoids installing a second ORT
version and overwriting its symlink target later. The shared 1.28.2 runtime
has been loaded in the pinned Ubuntu 24.04 container with API 27, and both the
OpenVINO and WebGPU provider libraries registered successfully. This verifies
runtime compatibility and packaging; it does not establish device inference
performance or qualification.

The standalone PME developer build retains its pinned default runtime, and
explicit developer runtime/provider variants remain available.

### Samsung neural provider packaging

Normal Android builds run `buildAndroidSamsungLiteRtRuntime` before staging
LiteRT. The portable bootstrap verifies an immutable archive of the Apache
LiteRT compiler/dispatch adapters and downloads the original Samsung AI LiteCore
1.2.0 SDK separately. It stages Android ARM64 object libraries and licensing on
Linux, macOS and Windows build hosts with Python 3.9 or newer. Native source
compilation is available through the maintainer builder with LiteRT v2.3.0,
Bazel 7.7.0 and NDK 29.0.14206865. The FlatBuffers link fix and ARM64 output
configuration are recorded with the source and artifact receipts.

The downloaded SDK stays in private task storage outside public Actions caches.
The shared adapter archive contains the two compiled Apache adapters, their
license and provenance. The APK additionally embeds the original vendor object
libraries, original licensing, hashes and source receipt. Validation rejects
changed pins, missing libraries, corrupted bytes and host-architecture payloads.
Both new JNI adapters have 16 KiB ELF alignment. Vendor LiteCore objects remain
unchanged in their runtime asset layout; device/loader compatibility and NPU
execution use runtime detection, fallback and physical device qualification.

## Linux graphics loader dependencies

The verified native prefix supplies the pinned Vulkan loader needed by the new
FEL/PME build (at least 1.4.309). Both release and package-smoke workflows copy
its complete `libvulkan.so*` chain next to shaderc before bundling. A native
archive without that loader fails the copy; the older Ubuntu system loader is
not a fallback for this build. Keep the host-Vulkan exclusion in `bundle-libs.sh`
so dependency harvesting cannot replace the pinned copy with a host library.

GPU ICDs and display-driver libraries stay on the host. The existing loader
package declarations (`libvulkan1`, `vulkan-loader`, `vulkan-icd-loader`) remain
for older/developer bundle compatibility, but do not prove the new loader's
version. PPA, COPR, AUR and Snap recipes continue to cover the canonical runtime
package lists, including Snap's time64 names. The common resolved bundle,
including the AppImage input, carries the pinned loader; validate Flatpak's
installed closure against its pinned runtime and extensions after rebuilding.

A bundled loader does not prove a usable GPU path. Retain per-architecture
`ldd`/package checks and accurate runtime diagnostics when qualifying PME Vulkan.
