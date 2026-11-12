# Complete Pleazyng releases

## iOS signing preflight

`build.yml` action `apple-signing-preflight` qualifies the existing distribution
identity and the distinct Runner/RommWorker App Store profiles on native hosted
macOS without compiling an application or changing a release. It is main-only,
has a ten-minute limit and uses a separate concurrency group; normal core builds
remain serialized. The retained report contains public certificate checks,
worker registration platform/case status and profile UUID, never a profile
payload or API credential. A successful preflight does not qualify an archive,
App Store processing, purchase/restore or device playback.

Apple defines [bundle IDs as case-insensitive](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier)
and [`UNIVERSAL` registrations as supporting all platforms](https://developer.apple.com/documentation/appstoreconnectapi/bundleidplatform).
The helper accepts those identities while requiring the exact full identifier,
case-sensitive team prefix, existing certificate, active `IOS_APP_STORE` profile
and native iOS CMS platform. Mac-only registrations, wildcard/prefix identities,
wrong teams/certificates, development/ad-hoc profiles and expired profiles fail.

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

Set a new version with `python3 scripts/set_release_version.py 3.0.31+190`.
This updates both `pubspec.yaml` and `webos/meta/appinfo.json`, preserving the
native app identity, permissions, and other metadata. Use the next unused
version and build number; never move an existing tag. The shared commit/CI
guards and release driver check this metadata before expensive work or tagging.

Run the complete release from an authenticated `gh` session. The driver verifies
native pins, creates an immutable `vVERSION-candidate.FULL_SHA` reference, then
captures one `build.yml` dispatch on `main` at that exact SHA. The run keeps its
source even if `main` advances. Its local reusable `ci.yml` comes from the same
commit. Every required CI child must pass before a separate job verifies the
GitHub job records and creates the stable version tag. All platform jobs remain
blocked until that qualification and tag binding succeed. A failed preflight
consumes no stable version; a new source receives a different candidate name.

Compatible Linux, Android, Tizen, Windows x64 and native Windows ARM64 jobs use
GitHub-hosted runners. Storage-heavy webOS remains private JIT. The captured
workflow retains its authorized `main` reference for private runners; neither
runner-group access nor broker policy needs to admit tags. No broker restart
or access expansion is part of this protocol. Source, compiler, final assembler
and stable tag all retain the same SHA.

Use `--source-commit FULL_SHA` to resume the recorded cut. Existing matching
runs are reused; later main changes are not incorporated. Record `ci_mode`,
`ci_run`, `candidate_ref`, `release_run` and `embedded-ci-proof.json` with the
qualification and artifact evidence. Embedded CI is reported as children of the
build run, not as a standalone `ci.yml` run.

Use `--skip-discord-notification` when manual announcement dispatch is outside
the operator's authorization. Package and store delivery still runs. This flag
does not change release-event workflow activation; control that separately and
restore any temporarily changed activation state after the operation.

If a later platform fails, recovery verifies the original build's current-attempt
embedded CI records, successful source freeze, immutable tag and source-bound
job contract. The platform failure does not invalidate passing CI, but failed or
missing CI never falls back to another run. Older releases retain their separate
`ci.yml` proof. Reuse successful platform artifacts under the existing product
equivalence checks; do not dispatch another complete build for a delivery error.

## Apple native qualification

Apple native reliability CI remains on hosted `macos-26` ARM with explicit
Xcode 26.5. Full iOS and tvOS package jobs use the release controller's
private-first capacity route: it selects private when the Mac JIT slot is free,
falls back to hosted when private is occupied and no hosted Apple package is
queued, and returns to private when hosted Apple work is already queued. The
private queue controller starts the runner on demand and serializes jobs on
the single Mac slot. GitHub does not expose global hosted macOS capacity, so an
already queued hosted Apple package in this repository is the busy signal. The
controller reads `q.home`'s fresh broker scan and APFS gate; an offline GitHub
runner alone does not prove that the private Mac can launch a job. Hosted queue
checks include both release builds and Apple reliability CI.
Use `--apple-arm-runner-pool hosted|private` only to override the automatic
choice. Run the release through `scripts/release_all_platforms.py` so it can
probe capacity and launch the private JIT controller. Every Apple build still
checks ARM64, Xcode, simulator runtimes, and free APFS/NFS space; native tests
retain their full coverage.
Private images use their installed compatible toolchain and must qualify it.
The test selector creates a fresh job-owned simulator using an available device
type and runtime matching the selected SDK's major/minor version. It never
reuses or erases an existing simulator's app data. An ownership receipt binds
the new UUID to the run, attempt, job and source. After test consumers exit,
cleanup checks the receipt and device identity before deleting that device;
cancelled jobs retain it for inspected cleanup. Retain the receipt with CI
evidence. Reused simulator recovery markers can correctly block normal database
startup, so they cannot establish a fresh-install qualification result.
Every native test, genuine tvOS framework and real database startup gate remains
required. Record the actual host/runtime qualification; software checks do not
establish physical HDR, hardware decoding, NPU or FEL reference accuracy.

The hosted tvOS release job uses an ARM macOS host, matching the pinned
ARM-host `gen_snapshot_arm64` cross-compiler. Simulator Debug/JIT tests do not
prove that Release AOT compilation can execute its host tool.

iOS Release packaging configures Flutter first, installs locked Pods, and
prebuilds `Pods-RommWorker` for device ARM64 using Flutter's same absolute
`BUILD_DIR`. Before app linking it resolves the worker's framework search
paths, verifies the staged native binary and records its digest. Keep the
verbose device link output: simulator success alone cannot establish the
device framework's availability.

The iOS and macOS mpv contract suites use a ten-second
`nativeCompletionTimeout` for eventual native replies and scheduler barriers.
This bounds the test harness while allowing simulator startup work; it does
not change production timeouts. Keep value, event-order, main-thread and
exactly-once assertions, synchronous pause-intent checks, measured playback
intervals and injected PiP timeout behavior intact. A failed completion guard
still fails qualification; do not skip it or infer a passing native result.

The real H.264 pixel test waits through XCTest so the main run loop remains
available, then checks decoded pixels and teardown. tvOS additionally waits
for the real Dart database bootstrap and checks its SQLite version against
the packaged source receipt. Failed iOS/tvOS XCTest bundles are retained as
`apple-native-results-<platform>-<run ID>` artifacts for diagnosis before
task scratch cleanup. Simulator results do not establish physical-device or
store qualification.

## Release job concurrency

Linux native qualification builds every registered focused test before CTest.
Explicitly requested ASan/UBSan and TSan instrumentation must be available.
Kernel mmap-entropy inspection and tuning are best effort; the tests still run
and any runtime startup failure blocks qualification. A successful compilation
with skipped execution is not runtime qualification. Provision a compatible
runner if actual execution establishes a capacity or kernel requirement.
The real dual-decoder test waits for each `mpv_terminate_destroy` to return
before measuring survivor progress or ending the process. Application teardown
stays asynchronous; the test's bounded completion checks preserve leak detection.

CI's Android, Linux native and server checks own their checkouts and setup and
consume no artifacts from the other suites. They start independently rather
than waiting for the application tests or for one another. The release gate
still requires all 13 CI jobs to pass on its exact source revision.

`validate-trusted-ref` is the short gate all build jobs wait for. Once it passes,
the independent platform jobs in one `build.yml` release run are eligible to run
in parallel; they do not wait for one another. `package-windows` waits for the
Windows build that produces its input, and `create-release` waits for all
required platform outputs before assembling the draft. Versioned releases and
nonpublishing build requests use separate concurrency groups, so an unrelated
queued package build cannot hold a release behind its runner wait. Old runs keep
the group assigned by the workflow revision that started them. The steps inside
each job still run in order.

Capacity determines which eligible jobs start. The hybrid Linux, Android,
Tizen, and Windows jobs can occupy separate hosted runners concurrently.
Apple native reliability checks and iOS/tvOS package jobs share the
private-first capacity route described above. WebOS uses its
own private Linux route and can remain queued until that compatible capacity is
available; it has no dependency on an Apple job. The stage-by-stage waits in
`release_all_platforms.py` protect the exact
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

The tvOS embed phase derives each framework's `MinimumOSVersion` from the
maximum of the application floor and every selected-platform Mach-O slice.
Pinned FFmpeg frameworks can carry stale SDK metadata in read-only plists;
correct only the build-owned copy, materializing cache symlinks first. Preserve
genuine higher binary floors, including optional Dolby Vision runtimes, and
reject missing, unreadable or wrong-platform load commands. Run
`python3 scripts/checks/test_tvos_framework_metadata.py` on a Mac with Xcode
to exercise real load commands and source-cache preservation. For Apple
blockers, retain task-owned incremental DerivedData until the complete app
build and native test bundle pass before spending another full CI run.

Normal releases and resumptions reuse the captured main workflow at the frozen
source SHA. The driver checks remote candidate/stable targets and canonical-main
ancestry before publication. Later main application changes belong to a future
cut. Delivery workflows use current trusted main tooling against immutable
artifacts, with the tooling SHA recorded separately from product source.

Explicit platform recovery retains its separate unchanged-product allowlist
and source-run proof. It may use newer release infrastructure without changing
the original product bytes. Do not add application source to that allowlist or
reuse one product's qualification for another. Existing tags are never moved.

Native dependency downloads are staged by `scripts/prepare_native_downloads.py`
after locked Pub resolution and before Dart hooks run. SQLite assets retain the
hashes from the resolved locked package; libdovi retains the four Gradle pins.
The helper requires matching GitHub asset metadata, verifies downloaded size and
SHA-256, retries fresh API redirects, and atomically caches only verified bytes.
It populates SQLite's existing shared hook cache; the unmodified hook verifies
those bytes again. Android's task-local curl wrapper serves only the four exact
pinned libdovi download commands and delegates every other invocation. AppImage
uses an independently checksum-pinned runtime via `--runtime-file` instead of an
implicit unverified rolling download. Never weaken hashes to accept an HTTP
error body. Older GitHub assets may lack an API digest: their independent source
pin and downloaded full SHA-256 remain mandatory; a conflicting API digest is
always rejected. PDFium retains the locked package's chromium/7811 release and
uses independently pinned archive hashes before extracting the one regular
library. Gradle keeps its original URL, version and SHA; prefetch stages its ZIP
in the Wrapper's normal URL-keyed cache, then the original Wrapper verifies and
extracts it. Never fabricate the Wrapper's completion marker.

Linux's pinned CMake archives are staged in their normal download directories;
CMake retains URL_HASH verification/extraction. Android shares verified source
trees through FETCHCONTENT_SOURCE_DIR overrides in the task's Gradle init policy.
Its native binary directories remain private to each ABI; do not share
FETCHCONTENT_BASE_DIR across Android architectures. Windows's existing pinned
source downloaders retain Schannel and full hash verification, with API fallback
on transport failure; executable tools still require Authenticode. The pinned
patched engine and webOS toolchains use the same API verifier without changing
versions or signatures. The commit/CI guards also run all webOS packaging tests, including
canonical and historical repository provenance URLs.

```sh
python3 scripts/release_all_platforms.py --version 3.0.1 \
  --execution-profile hybrid --publish-github-only \
  --include-webos-release \
  --ffmpeg-source-cache /mnt/disks/scratch/task-scratch/plezyng-release-3.0.1-20261103/ffmpeg-preflight \
  --scratch /mnt/disks/scratch/task-scratch/plezyng-release-3.0.1-20261103/release-final
```

The core command builds every required platform, verifies its artifacts and
checksums, then publishes GitHub. After delivery checks, it runs
`scripts/refresh_release_facts.py --tag vVERSION` and pushes only the generated
README, capability ledger and independently fetched publication snapshot from a
fresh `main` worktree with an ordinary fast-forward push. It never pushes the
frozen product checkout over later development. The
immutable build tag remains unchanged. A metadata refresh failure is recorded
as a separate follow-up, preserving the published release; retry the same helper
rather than rebuilding binaries. The live CI check resolves the actual tag
commit separately from GitHub's `target_commitish`, which can be `main`. It records that success before attempting
Discord or configured distribution channels. Delivery failures remain in the
summary for separate repair/retry against the immutable release; they do not
turn publication into a failed core build. WinGet and Chocolatey metadata are
attached when produced, while installers and all required Linux formats remain
mandatory. See [channel retries](release-channel-retries.md).

The Android CI bootstrap disables Gradle file-system watching in the job's
Gradle user home, preserving other properties and all dependency caches. A
release build stopped producing output after `Already watching path` for
Flutter's included Gradle build; it reached the six-hour limit with ample
available memory. Use Gradle's supported `org.gradle.vfs.watch=false` setting
rather than changing SDK pins or treating that evidence as an OOM. The release
commands use verbose Flutter/Gradle output and `scripts/run_android_build.py`:
it emits minute heartbeats and bounded JVM thread diagnostics every ten minutes,
preserves the build's exit status, and forwards cancellation only to its own
process group. It never stops a build based on CPU or I/O pressure. See
[Gradle file-system watching](https://docs.gradle.org/current/userguide/file_system_watching.html).

Android SDK preparation verifies installed package files and pinned NDK metadata
before making network requests. It reuses qualified packages unchanged, avoiding
an unnecessary upgrade of the hosted image's working platform-tools. Only
missing or invalid packages go through SDK Manager; license and installation
requests retry up to three times, and the original post-install verification
remains mandatory. Persistent failures and wrong NDK versions still fail the
build. Keep the SDK/toolchain pins unchanged when repairing download transport.

GitHub's release API checks workflow-write authorization against the supplied
`target_commitish`, even when a historical version tag already exists. The
release job verifies that the remote tag still resolves to the exact validated
source (including annotated tags), then uses `target_commitish: main`, which
GitHub ignores for an existing tag. This retains the immutable compiled source
and normal `contents: write` permissions without a broader token. Do not change
the tag or rebuild native platforms to repair this API authorization failure.

Use explicit signing and Homebrew qualification options separately when those
preparations are requested. They require signed iOS/tvOS archives and a
notarized macOS Cask candidate, even for GitHub-only publication. They do not
enable store uploads or tap publication. Successful-run reuse checks the requested
signing, notarization and Cask steps; asset validation requires both signed IPAs
and `snapetech-pleazyng.rb`. These options default off. Store qualification
requires a full store build and cannot use platform-artifact recovery. Cask
qualification may reuse a repaired Mac build only after its full compilation,
notarization and Gatekeeper steps succeed, or qualify a fresh Mac rebuild;
recovery never infers those checks from a DMG's presence alone.

The default frozen protocol captures CI and the complete platform build in one
main workflow. It creates the stable tag only after authoritative exact-source
CI proof, then compiles the release matrix once. Publication waits for every
platform and artifact check. A product fix after stable tagging requires the
next version; never move a tag or replace published assets. Explicit legacy
main/recovery mode remains available with `--no-freeze-release` and preserves
its unchanged-product source and CI checks.

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
submit builds for review. Google Play delivery targets the configured internal
testing track; successful delivery does not establish installation or review
qualification.
Microsoft Store, Samsung Seller Office, macOS Developer ID signing, Windows
Authenticode signing, and vendor-store publication require their configured
identities, profiles, and credentials. These store channels do not gate the
complete GitHub release.

The orchestrator uses the current machine's GitHub CLI authentication only for
workflow dispatch, repository commits, and the version tag. Its default hybrid
profile sends compatible jobs to GitHub-hosted runners, routes iOS/tvOS packages
private-first with capacity fallback, and uses private JIT for storage-heavy
WebOS and other private-resource work. The script does not
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

### Public downloads and build evidence

Public downloads contain installable packages, update feeds, checksums and provenance needed by consumers. WebOS app/engine provenance and compatibility JSONs are retained inside `pleazyng-lg-webos-submission.zip` and producer CI artifacts instead of duplicated as individual release assets. Extract the handoff ZIP to inspect its evidence. macOS compilation-recovery reports stay in CI artifacts and attestations. Fire TV provenance remains a separate verifiable companion to its APK; reuse provenance is published only when release assembly actually reuses verified platform builds. The Discord delivery receipt remains durable release state used to prevent duplicate or uncertain message delivery; do not remove it as cosmetic cleanup.

Native-hook download audit: the resolved application has SQLite, PDFium, SMB,
and Objective-C hooks. Objective-C compiles locally. Prefetch the other three
before invoking Dart, and preserve their original cache layouts and full hashes.
SMB uses its resolved hook's release and asset hash table (including Apple
XCFramework archives); tvOS retains its existing AMSMB2 stub. Apple torrent
archives go into `build/p2p/dependencies` before CocoaPods invokes the unchanged
native builder. Linux libmpv and offline HDR/SDR runtime fetchers use the same
verified API path, with the existing pin and extracted-runtime checks retained.

The private webOS job prefetches the exact actions/python-versions Python 3.14.8
Ubuntu 24.04 x64 archive before setup-python. It checks the archive's pinned
SHA, uses the upstream installer to populate the runner's normal tool cache,
and checks its version and completion marker. Complete matching caches are
reused; partial or mismatched caches are retained and rejected, never replaced.
The later setup-python action remains and verifies/discovers the same version.

For a webOS-only infrastructure failure, preserve successful platform outputs.
Stop only the local failed-run monitor (never its remote jobs) before starting
`scripts/launch_queued_apple_jit_jobs.py RUN --evidence-dir TASK_SCRATCH --continue-after-platform-failure`;
otherwise that monitor intentionally drains/cancels the obsolete queued Apple
jobs. This explicit recovery mode still waits for the single physical Mac and
its cleanup, and stops launching after any Apple failure. After the source run
finishes, use the driver with `--reuse-platform-run RUN --reuse-android-run RUN`
to rebuild webOS and assemble the verified original outputs. Every reused
platform job must have succeeded; no platform is omitted. Recovery records the
actual tag CI source separately after verifying tag ancestry and the complete
infrastructure-only diff. A native-download-helper change is accepted only
inside the webOS Python bootstrap function; any changed native pin or other
transport/compiler input rejects recovery. The pinned Python installer and
cache checks use the destination's `lib` directory in `LD_LIBRARY_PATH`, as
setup-python normally does. Fresh installation and completed-cache reuse were
both verified in an isolated Ubuntu 24.04 container.

Add `--rebuild-tvos` when only the tvOS release job failed. Once the original
run finishes, explicitly pass `--reuse-android-run SOURCE_RUN_ID` and
`--reuse-webos-run SOURCE_RUN_ID` alongside `--reuse-platform-run SOURCE_RUN_ID`
to retain those successful artifacts too. This rebuilds only tvOS on the ARM
host, requires its fresh job to succeed, and downloads the other platforms
only after verifying their completed jobs, immutable source and digests.
Application sources and native pins must remain unchanged; the existing tag
and version stay immutable. `--publish-github-only` publishes the complete
validated core release; configured channel delivery then uses those same
artifacts. Never treat the original missing tvOS artifact as reusable.

Use `--rebuild-ios` for a failed iOS package, independently or alongside the
other explicit rebuild flags. Fresh iOS and tvOS artifacts must come from
successful jobs in the recovery run. A failed original webOS job remains a
fresh build; do not pass it as `--reuse-webos-run`. The webOS-only SDK
atomic link repair is accepted solely as exact additive CMake statements on
the existing worker targets; arbitrary flags, source edits and native pin
changes still reject reuse. Both worker targets use the SDK's shared `libatomic` ABI, which LG's
generated runner already links. The SDK contains no static atomic archive;
the native preflight verifies the shared ABI before the full build.

Add `--rebuild-linux` to the recovery driver when a Linux job failed: both native
Linux matrix entries build again, their old artifacts are excluded, and every
Linux format remains required before publication. Keep `--prepare-homebrew-cask`
when the source Mac job performed notarization and Gatekeeper qualification;
preflight may wait for that job, but final artifact recovery rejects missing or
skipped qualification steps. `--reuse-android-run RUN` can reuse a completed
successful Android job while other platform jobs in the same trusted source run
finish. All reused jobs, archive hashes and source identities are rechecked at
assembly. Download progress belongs on stderr: `fetch_dv_tools.py` stdout is
consumed as exactly one filesystem path by CMake.

Source recovery polls at most once a minute while Apple jobs finish. Each full
proof rechecks GitHub source, job and CI evidence; the interval leaves API
capacity for final artifact verification and publication. Active builders keep
running throughout this status wait.

Use `--rebuild-macos` if the source Mac job failed before producing its qualified
DMG. This excludes the source Mac artifact and requires a new universal Mac
build, signing, notarization and Gatekeeper verification when
`--prepare-homebrew-cask` is selected. It can accompany `--rebuild-linux`; it
cannot accompany signing-only `--reuse-macos-run`. Other successful platform
outputs still require the complete source and digest proof.

Apple PDFium also has a CocoaPods download separate from the Dart native hook.
The prefetcher reads the original locked `pdfium_flutter` podspec URL and SHA,
fetches that same XCFramework ZIP through the GitHub asset API, and installs a
job-local curl wrapper for only that exact CocoaPods command. CocoaPods retains
its own ZIP verification and extraction. Other curl invocations are delegated,
and neither the dependency source nor its version/checksum is edited.

Recovery preflight may identify a still-running Android source job, so independent
Linux, webOS and Mac repairs can start in parallel. This is deferred evidence,
not permission to reuse unfinished outputs: final assembly waits for source
completion and requires Android success, a matching artifact and its full
digest before downloading or publishing it.

If Linux and macOS were repaired successfully but webOS still failed, pass
`--reuse-repaired-run RUN` alongside the original `--reuse-platform-run` and
`--reuse-android-run`. It replaces only the two Linux jobs and the full Mac job.
The repair source must be a trusted main release of the same version, with
unchanged Linux/Mac job definitions and SDK environment. Final assembly requires
their success, the Mac compilation/notarization/Gatekeeper steps, source identities
and artifact digests. Pending jobs are allowed only during preflight. Do not
combine this option with fresh Linux/Mac builds or signing-only recovery.

The webOS runner uses the standard message codec from the already bundled
`libflutter_common.so`; link the SDK `flutter` interface directly after including
the generated build graph. Header-only syntax checking cannot detect a missing
direct link. The early ARM preflight now also requires
`WEBOS_ENGINE_ARM_ARCHIVE`, validates the archive and common-library hashes, and
links a codec probe with undefined symbols forbidden. Immutable-tag/recovery
checks allow only this exact one-line CMake addition; other CMake changes still
require a new version and fresh qualification. Application C++/Dart sources and
native dependency pins are unchanged by this link repair.

If the webOS job passed but release assembly failed before `Create Release`, add
`--reuse-webos-run RUN` to the verified platform-recovery command. Its complete
successful webOS job, unchanged SDK environment/build steps, source identity and
artifact digest remain mandatory; a failed publishing step cannot be reused as
proof that no release was created. The controller waits locally for remaining
source jobs before dispatching an assembly-only workflow, so waiting does not
occupy a hosted runner. The public provenance records the webOS package's actual
source separately from the assembly revision.

Release assembly checks out `scripts/**`, including transitive imports, and runs
an import smoke check before downloading artifacts. The regression suite creates
the actual Git sparse checkout in an isolated repository and imports its recovery
helpers with Python isolation enabled; adding a helper must not create another
late assembly failure after successful platform builds.


### Frozen Apple packaging recovery

Prepare pinned iOS Steam sources in `PLEZYNG_APPLE_WORKSPACE` before Xcode.
The bounded preflight retries preparation three times within 15 minutes and
keeps the existing dependency revisions and patch verification. The later
Xcode phase reuses the matching recipe marker from that same source copy;
preparing only the original checkout does not populate its inputs.

When only Apple packaging fails after source qualification, preserve the stable
product tag and successful platform artifacts. Create one reviewed packaging
commit whose sole parent is the qualified product commit; it may change only the
explicit metadata paths in `scripts/verify_frozen_packaging_repair.py`. Merge that
commit into main, then record its exact changed Git blob inventory in
`.github/release-packaging-repairs.json` on main. Application sources, dependency
pins, native binaries and version numbers cannot change in this exception.

The trusted main workflow independently verifies the approval, complete Git trees,
and ancestry before checking out the packaging revision. `GIT_COMMIT` retains the
qualified product identity. Build-source copying uses the packaging identity;
workflow authorization retains the dispatched main identity. Request only the
failed Apple rebuilds, with signed Store archives enabled, and reuse Android,
webOS and other successful jobs from the original release run. Do not dispatch a
second all-platform build. Native-fork HEAD movement does not invalidate unchanged
pins in an explicitly approved frozen repair.

For the `v3.0.33` Apple recovery, validate the RommWorker App Store profile
against every checked-in Enhanced Security entitlement before archiving. A
stale active profile is not sufficient merely because its bundle, team and
certificate match. If hosted macOS ARM capacity cancels tvOS before it starts,
select the private Apple ARM lane only after checking its live Xcode, NFS and
local scratch capacity. Rebuild only the Apple jobs that failed; preserve the
successful source run's platform artifacts and immutable product tag.

The assembly publishes a schema-2 `platform-reuse-provenance.json` bound by the
attested SHA256SUMS manifest. It identifies product, packaging and workflow SHAs,
original and assembly run IDs, exact reused artifact IDs/digests and Linux archive
hash. The controller verifies the attestation and receipt before publication.
Signed Store steps, notarization, Gatekeeper acceptance and full platform coverage
remain required. Public release notes include the full upstream attribution ledger.


Build jobs explicitly evaluate after intentionally skipped capture/CI ancestors
and still require successful source validation. A corrected workflow snapshot
may retry the same packaging revision only when the complete trusted prior-run
inventory proves approved source validation succeeded, every other job (including
both repaired platforms and release creation) skipped without steps, and no
artifacts exist. Preserve that validation-only run as evidence. Any actual build,
publication attempt, artifact or incomplete inventory blocks this exception.


Apple workspace cleanup binds source validation to `COMPILE_SOURCE_SHA` while
private scratch ownership remains bound to the real workflow `GITHUB_SHA`.
The two identities differ in an approved frozen repair; do not overwrite workflow
identity globally or weaken task-path/owner checks.

If a signed tvOS repair succeeds while iOS fails, retain its compiler run and use
`--reuse-tvos-run` during the next approved, iOS-only packaging recovery. Its
previous packaging revision must independently qualify as an approved sibling of
the same frozen product. The prior run must contain the actual successful signed
TV build, both package attestations and upload, with no publication attempt.
For a tvOS-only sibling, the iOS job is skipped; accept its failed release
assembly only when artifact recovery failed and the Create Release step was
skipped. The later iOS-only repair still checks the exact signed TV artifact
ID, digest, source and workflow identities before reuse.
For `v3.0.33`, the original hosted iOS archive reached GitHub's six-hour limit
after the unsigned checkpoint. Route its focused signed rebuild to the private
Apple Silicon runner after the tvOS job finishes; keep the source version and
successful platform artifacts unchanged.
The producer pins the exact TV artifact ID and digest, verifies both IPA
certificates against their original workflow/run, and publishes a distinct
`tvos_source` proof. Ordinary Linux/Mac repair reuse keeps its existing meaning.
The existing workflow `reuse_repaired_run_id` slot is interpreted as TV reuse only
for this explicit frozen Apple mode; no additional dispatch input is required.
After both signed Apple siblings are complete, an approved assembly-only repair
can use `--reuse-tvos-run` and `--reuse-ios-run` together. The existing workflow
slot then carries `tvos:RUN,ios:RUN`. Verify each sibling's signed build,
attestations, unpublished assembly and exact artifact ID/digest. Original
platform artifacts remain bound to the frozen product source SHA, while Apple
sibling artifacts remain bound to their own workflow source SHA. No platform
jobs rebuild for this assembly-only repair.


Before iOS compilation, signed releases validate the Runner App Store profile and
prepare a separate `org.snapetech.pleazyng.RommWorker` App Store profile through
the existing Apple API key. The API certificate must exactly match the imported
Apple Distribution identity before any bundle/profile creation. Reuse a valid
worker profile; create only the explicit worker bundle/profile when needed.
Never rotate certificates or overwrite another target's profile. The worker does
not request the host app group; Runner and TopShelf retain that requirement.
All targets still require exact bundle/team/certificate, unexpired Store profiles,
matching platforms, and no development, ad hoc or enterprise provisioning.

The generated worker profile is masked and passed only through the current job's
environment; API keys and installed temporary profiles are cleaned up. API access
failure stops before expensive compilation. A locked human Apple web login does
not establish whether the independently authorized API key works. The unsigned
iOS IPA is attested and uploaded as `ios-unsigned-checkpoint` before Store
packaging; it does not substitute for the complete final `ios-ipa` artifact or
qualify Store distribution. Final assembly still requires the signed archive.

### Immutable Apple authentication podspec

The iOS and macOS Podfiles fetch GTMAppAuth 5.0.0 metadata from
[the exact official CocoaPods specification](https://github.com/CocoaPods/Specs/blob/fd8ca834492e570dddaffabba6a5a1c12b5e92c3/Specs/2/c/c/GTMAppAuth/5.0.0/GTMAppAuth.podspec.json).
The upstream edit added only `deprecated: true`; its Google source tag and
all dependency versions remain unchanged. CDN edges returned both metadata
versions and broke `pod install --deployment`. Keep the immutable URL and
checksum together in both lockfiles. External podspecs are normalized into
sandbox JSON: use its CocoaPods 1.17 checksum, not the raw Trunk document hash.
`check_podspec_locks.rb` verifies that
contract before native compilation; do not bypass deployment enforcement or
accept whichever checksum an edge returns. A future dependency upgrade must
review its source, metadata and both resolved dependency graphs together.
