# One-command PlezyNG 3.0.0 release

After exact-main CI and platform canaries pass, run the complete 3.0.0 release
from an authenticated `gh` session. Compatible Linux, Android, Tizen, Windows
x64, and native Windows ARM64 jobs use standard GitHub-hosted runners. Apple
builds and the storage-heavy WebOS candidate use compatible private JIT runners.
The hybrid execution profile routes each job to the compatible runner class;
the broker pool remains available for jobs that need private capacity.

## Release job concurrency

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
native-manifest, CI, candidate, tag, and release gates; they do not serialize
independent platform jobs inside the dispatched release workflow.

For Apple queue inspection and the one-job JIT launcher, see the
[Apple JIT runner runbook](apple-jit-runner.md).

Release actions reuse an existing immutable version tag. If the tag is an
ancestor of `main`, the workflow permits only release infrastructure, changelog,
maintainer documentation, and the WebOS compatibility lock to differ from the
tagged commit; application-source changes still require a new matching tag.
Both the workflow and the local release driver enforce this allowlist, and the
draft release remains tied to the existing tag.

```sh
python3 scripts/release_all_platforms.py --version 3.0.0 \
  --execution-profile hybrid --publish-github-only \
  --ffmpeg-source-cache /mnt/disks/scratch/task-scratch/plezyng-release-3.0.0-20261103/ffmpeg-preflight \
  --scratch /mnt/disks/scratch/task-scratch/plezyng-release-3.0.0-20261103/release-final
```

The command validates CI on the exact current `main` SHA, then runs the complete
release build. When a version tag already exists, it reuses that immutable tag
only if it is an ancestor of `main` and the intervening changes are on the
release allowlist; the release workflow builds the full platform matrix. For a
new version, it first verifies or refreshes native artifacts, updates their
pins, validates CI and a nonpublishing candidate, and only then creates the tag.

If the control-plane host cannot reach `ffmpeg.org`, pass
`--ffmpeg-source-cache <directory>` with retained files named
`ffmpeg-<pinned-version>.tar.xz`, `ffmpeg-<pinned-version>.tar.xz.asc`, and
`ffmpeg-devel.asc`. The orchestrator copies those files into the new scratch
directory and still requires a valid signature from its pinned FFmpeg release
key before it records a checksum or changes PlezyNG's pins.

When a completed native run has failed platforms, the orchestrator can recover
other groups whose publishing jobs succeeded. It checks the manifest artifact's
GitHub digest, the current source content keys, and every published asset's
checksum before recording that group on native `main`. Only manifests from an
explicit native build of an ancestor of current `main` are eligible. The next
native build then rebuilds only the groups still stale. A partial recovery never
updates PlezyNG's pins or bypasses the final all-platform verification.

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
3.0.0 hybrid profile uses `windows-2025` for x64 and the native
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
It pushes that focused pin update to PlezyNG `main`, waits for CI on that exact
commit, and runs a complete nonpublishing `action=build`, `mode=release`
candidate with webOS and Tizen enabled. The immutable `v<version>` tag is
created only after that candidate succeeds; the tagged `action=release` run
then assembles and validates the draft release. Both runs use the same exact
`main` commit. The candidate build compiles the webOS and Tizen ARM artifacts
by default. The validated Tizen tester package and its re-signing handoff are
attached to the versioned release. The webOS IPK remains excluded from public
release assets until the existing artifact eligibility gate passes and the
operator opts in. Apple jobs refresh their SwiftPM mirror after the native pin
changes.
Before publication, the orchestrator checks that every required release asset
exists. `--publish-github-only` promotes the verified GitHub draft without
dispatching store, package, container, appcast, or Discord workflows.
`--publish` promotes the draft and sequentially dispatches configured channels.
It
reuses successful channel runs and stops on a prior failed run rather than
repeating an external side effect blindly.

The webOS candidate is built privately and kept out of public release assets
unless the existing artifact eligibility gate passes and the operator opts in.
Only after that approval, the release may be rerun with:

```sh
python3 scripts/release_all_platforms.py --version 3.0.0 \
  --execution-profile hybrid --include-webos-release --publish-github-only \
  --ffmpeg-source-cache /mnt/disks/scratch/task-scratch/plezyng-release-3.0.0-20261103/ffmpeg-preflight \
  --scratch /mnt/disks/scratch/task-scratch/plezyng-release-3.0.0-20261103/release-webos-approved
```

Tizen remains a tester artifact for qualification; Seller Office signing and
submission are not configured. App Store Connect and Amazon uploads do not
submit builds for review. Google Play is sent to the internal draft track.
Microsoft Store, Samsung Seller Office, macOS Developer ID signing, Windows
Authenticode signing, and LG public IPK publication remain gated on their
missing identities, profiles, credentials, or artifact approvals.

The orchestrator uses the current machine's GitHub CLI authentication only for
workflow dispatch, repository commits, and the version tag. Its default hybrid
profile sends compatible jobs to GitHub-hosted runners and uses private JIT for
Apple, storage-heavy WebOS, and other private-resource work. The script does not
accept custom runner labels or store or print credentials.
It stops on a failed native group, FFmpeg signature, CI run, candidate build,
tag conflict, or release build. Re-running it reuses successful native,
CI, candidate, and release runs and never moves an existing tag.

If Android fails, merge the infrastructure fixes, then recover the
native run without rebuilding its entire matrix. Android and WebOS recovery may start while native
jobs are still running; release assembly waits for their successful completion:

```sh
python3 scripts/release_all_platforms.py --version 3.0.0 \
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
Recovery does not enable App Store signing, Homebrew notarization, or public
WebOS attachment. If a reused platform fails or product inputs change, fix and
validate that platform instead of broadening the recovery allowlist.

The final JSON receipt is written to the printed scratch directory. Temporary
checkouts and the verified source archive are removed after the workflow run;
GitHub retains the workflow logs and release artifacts. The scratch directory
and its receipt remain for review and should be cleaned only after the release
has completed and its outputs have been transferred or retained deliberately.
