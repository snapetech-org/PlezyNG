# Pleazyng Apple JIT runner

Full iOS and tvOS package routing is private-first. Before dispatch, the
release controller checks whether the on-demand private-apple-builds ARM lane
is occupied. If it is, the controller checks active hosted Apple jobs: it uses
hosted when no Apple package is queued, and selects private again when hosted
Apple work is already waiting. The private queue controller waits for the
single Mac slot and launches each selected job as soon as it is free.

This policy responds to the v3.0.33 hosted release, which waited 7h18 for its
Apple jobs, then the signed iOS job reached its six-hour limit while archiving.
A verified private Apple recovery completed iOS in 1h43 and tvOS in 26 minutes
([hosted release](https://github.com/snapetech-org/pleazyng/actions/runs/42992562384),
[iOS recovery](https://github.com/snapetech-org/pleazyng/actions/runs/43120491761),
[tvOS recovery](https://github.com/snapetech-org/pleazyng/actions/runs/43115287017)).
The release controller starts the runner on demand and serializes Apple jobs
because the lane has one Mac slot. Direct workflow dispatches default to the
private lane; the release controller can select either lane from live queue
state, and `--apple-arm-runner-pool hosted|private` remains available as an
explicit override. GitHub does not expose global hosted macOS capacity, so the
controller treats an already queued hosted Apple job in this repository as a
busy signal and prefers private when it observes one.

Apple native reliability checks in Release CI remain on GitHub-hosted runners;
they completed within 43 minutes in the same release. Linux, Android,
Windows, macOS desktop, and other compatible lanes also keep their hosted
routes.

## Pinned tvOS host tools on Apple silicon

The current tvOS engine bundle (`v3.47.1`) contains an Intel-only Dart 3.13.1
host runtime alongside ARM host AOT tools. The private ARM Mac needs Rosetta to
execute that pinned runtime. Keep its Dart version check; Flutter 3.47.8's Dart
3.13.7 cannot replace the older runtime or its frontend-server snapshot.

After confirming the lane is idle, install the compatibility component using
[Apple's documented method](https://support.apple.com/en-us/102527):

```sh
sudo softwareupdate --install-rosetta
sudo -u gha-jit-macos /Users/gha-jit-macos/.cache/flutter-tvos-engine/v3.47.1/out/host_release/dart-sdk/bin/dartaotruntime --version
```

The version probe must succeed as the runner service user. This is a build-host
dependency; the produced app and simulator frameworks remain ARM64 and require
their native tests. A successful host-tool probe does not establish tvOS app
qualification. Recheck the prerequisite after an OS upgrade or fresh builder
provisioning, and reassess it when the pinned engine's host tools change.

## Automatic queue handling

The release orchestrator starts `scripts/launch_queued_apple_jit_jobs.py` when a
PlezyNG run contains queued or active Apple JIT jobs. The controller watches
the run, launches one job at a time on the single Mac slot, waits for each job
to finish, archives its runner diagnostics, and removes only that completed
run/job/attempt directory before starting the next Apple job. The GitHub run is
left intact if the controller encounters an error.

Run releases through `scripts/release_all_platforms.py` with an empty task
scratch directory. The orchestrator stores controller logs and runner evidence
under `<scratch>/apple-jit-evidence/<run-id>/` and drives the normal GitHub run
watch concurrently. No manual hold/release/remove/start cycle is needed.

If a platform fails in a trusted main-branch build or release, the queue helper
finishes any active Apple job and its cleanup, then stops launching further
Apple jobs for that failed run. The release orchestrator waits for every active
job and any queued non-Apple packaging job to finish before canceling the
remaining obsolete Apple queue. It requires a complete job inventory and
preserves any run where release creation may have produced external side
effects. CI continues collecting all test results after a test failure.
Completed Apple job logs are retrieved through the job-log API while the
workflow is still running; evidence does not wait for the whole run to finish.

For an already-running workflow that is not being watched by the release
orchestrator, start the same queue controller directly:

```sh
run_id=YOUR_RUN_ID
python3 scripts/launch_queued_apple_jit_jobs.py "$run_id" \
  --evidence-dir /path/to/task-scratch/apple-jit-evidence
```

The controller accepts only trusted `workflow_dispatch` runs from PlezyNG
`main`. It serializes jobs with the run-scoped `gha-<run-id>-...` labels and
preserves launcher logs, GitHub job logs, and `_diag` archives in the supplied
evidence directory.

The iOS and macOS source workspaces use a shared local Git clone of the exact
job revision. This copies tracked sources without ignored caches, checkout
credentials, or APFS provenance attributes. The clone borrows Git objects from
the original job checkout, which must remain present until all job consumers
exit; it is task scratch, not an independently retained source archive. The
helper refuses modified tracked source or a nonempty destination. Existing task
ownership checks and AppleDouble checks remain in place.

Swift package resolution also uses the job's local APFS DerivedData path.
It must not fall back to `~/Library/Developer/Xcode/DerivedData`, where aborted
jobs previously left build output outside the runner cleanup root.
The launcher also checks default Xcode DerivedData workspace records after the
job exits. It archives matching logs (and all build products after failure),
then removes only output belonging to that run and attempt. Other workspaces
and shared caches remain available.

The DerivedData helper waits up to 30 seconds for service-user `Runner.Listener`
and `xcodebuild` consumers to exit, including consumers from other jobs. It only
starts cleanup after observing neither process. The wait includes process-query
time; a persistent consumer, failed query, or query timeout leaves all output in
place and fails the launcher for diagnosis. This handles a listener that is
still exiting after GitHub reports job completion without bypassing the global
consumer check. Exact runner/workspace ownership and diagnostic retention checks
still apply.

## Cancelled build process trees

The launcher supervises its one-job runner with
`scripts/apple_jit_process_tree.py`. Before polling/reaping the runner, it saves
kernel process identities and ancestry under `_diag/process-tree.json` on local
APFS. Captured build descendants remain associated with their job after their
parent exits or they are reparented to PID 1. Executable paths, numeric UID,
parent/group IDs, and kernel creation time are recorded; arguments, environment
values, and JIT configuration are never read into process evidence. The Darwin
identity layout follows [Apple's public process-info header](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h).

An observer failure marks the journal incomplete and leaves the runner and its
files intact for diagnosis. It does not authorize killing an active job.
The supervisor and teardown helper share a nonblocking job-specific lock.

After a cancelled job exits and its runner registration disappears, the
launcher fetches fresh run and job records. Teardown requires both records to
be completed/cancelled for the exact trusted-main repository, run, job and
attempt. It refuses incomplete/mismatched process evidence and waits for old
`Runner.*` control processes to exit naturally. Active jobs in other runner
roots, runner listeners, post-job cleanup branches, and other UIDs are preserved.

Before any SIGTERM, teardown captures the current tree and persists the full
set of descendants and cancellation proof. It rechecks each PID's UID and
microsecond creation time immediately before signalling it, then retains those
identities across reparenting and retries. Only build branches belonging to
this job are eligible; no process group, name-wide kill, or SIGKILL is used.
If consumers remain after the bounded grace period or inspection fails, all
runner files and process evidence remain available. DerivedData cleanup and
diagnostic archival run only after this guarded drain succeeds. A nonzero
cancelled-runner exit cannot skip these checks or turn cancellation into success.
Workflow scratch cleanup retains cancelled-job output before any copying or
deletion, using the explicit `APPLE_JIT_JOB_STATUS` passed by every Apple
cleanup step. Otherwise it uses a read-only observer check while the runner is
alive, and refuses to remove source or local Xcode output if owned build
consumers remain. After a cancellation, the launcher archives diagnostics and
retains the runner and any blocked scratch for owner-reviewed retention and
exact-path removal. It does not automatically delete failed build evidence.

This path still relies on observed ancestry: a short-lived intermediate that
creates a new session and exits between samples may leave an unobserved global
executable. Ordinary same-group orphans are captured before the supervisor
reaps its direct child; a remembered group number is never used to infer
ownership after that child has been reaped.
Do not infer ownership from its name or kill a host-wide compiler to force
cleanup. The existing global idle check remains a backstop; retain blocked
output for manual inspection. Changes to this supervisor require a disposable
Mac cancellation exercise before deployment, including PID-1 reparenting and
an unrelated active-job preservation check. The 2026-11-07 on-device exercise
verified Darwin kernel identities, captured an owned orphan, drained it with
SIGTERM and preserved an unrelated active process. Build a fresh small fixture
executable with `xcrun clang`; relocating signed `/bin` programs can cause macOS
to terminate the copied program before the observer can inspect it.

The build-only NFS export on kspld0 is configured in
`/etc/exports.d/plezyng-mpv-build.exports`. Keep its reproducible scratch data on
`async` writes; `sync` made metadata-heavy workspace copies, Git checkouts and
DMG staging take many minutes. The authorized Mac client remains its stable
Tailscale IP `100.64.0.3`, so DHCP LAN address changes do not alter access. Preserve
all client, ownership and root-squash options. Update only this export with
`exportfs -i -o` using the complete existing option list; do not restart active
runners or reload unrelated exports. This scratch policy permits write
acknowledgement before stable storage and is not a policy for personal data.

Before each launch, the controller also changes the Mac's default
`net.inet.tcp.delayed_ack=3` to `0`. The measured 12-file NFS probe improved
create/fsync time from 1.00 to 0.27 seconds and unlink time from 0.78 to 0.24
seconds. The setting resets after reboot, so the launcher reapplies it; a
failure to tune it is non-blocking. An already-set `0` or a custom `1`/`2` is
left alone. See the [NAS vendor's macOS performance guidance](https://www.dell.com/en-us/infohub/articles/powerscale-onefs-macos-client-performance-and-user-experience-optimization).

The iOS CocoaPods permission pass was also profiled spending most samples in
`chmod` over NFS. If metadata latency still dominates, use a short local APFS
source/Pods workspace and retain NFS for caches and archives. Preserve the
matching owner records, path validation and cleanup support when changing that
layout; do not remap an active workspace or treat the permission pass as a
stopped compiler.

Steam sources prepared under `.dart_tool/games/steam` are reusable between
Apple platforms when `.plezy-recipe` matches the script, source lock and patches.
Preserve a completed source cache before removing the creating workspace,
record its archive digest and source run, then restore it into a later task
workspace before its source-preparation consumer starts. Verify the task owner,
source SHA and recipe; leave an already-started preparation untouched. Compiled
archives remain architecture-specific.

Flutter 3.47.1 applies a negative-lookahead regular expression to every
nonverbose macOS build-output line. Nested native builds emit linker commands
around 40 KB long; the filter scans those lines repeatedly and can leave Xcode
blocked writing its log while the Flutter tool consumes a core. The 3.0.4
build confirmed this with process samples, and the matching Dart 3.13.1 probe
took 6.26 seconds for a 16 KB line and exceeded 25 seconds for a 40 KB line.

Keep `--verbose` on the macOS release build command. In this pinned Flutter
version it bypasses the output filter and streams the original compiler output;
the Xcode exit status still determines build success. Verbose mode processed
the same probe lines in about 25 microseconds. Observe actual child processes
and output timestamps when diagnosing a quiet build; preserve its artifacts
and active consumers. This setting changes logging, not release optimization
or the packaged native features.

## Single-job troubleshooting

### Check signing before compiling macOS

Gatekeeper assessment must receive the app's canonical local APFS path. The
normal source workspace is private NFS, and its `build` symlink points to local
Xcode output. Passing the NFS path to `spctl` fails with `Permission denied`
even when the caller can read it. A native Mac reproduction with Apple's
signed Calculator app passed at its direct APFS path, failed through a mode-700
NFS directory, and passed after `Path.resolve(strict=True)`. The workflow
resolves the app path before assessment; keep the NFS ownership, permissions
and root-squash policy intact. A failure at this stage after successful native
compilation uses the retained compilation and signing-only recovery below.

SwiftPM can copy framework binaries into the application with mode `555`.
`prepare_macos_app_for_signing.py` adds only the owner's write permission
inside the owned app before signing. It validates the complete bundle boundary
first, rejects external symlinks and foreign-owned files, preserves executable
bits and file contents, and leaves shared dependency caches untouched. This
fixes the observed `AetherLibdav1d.framework` signing permission failure.

After universal compilation validation, the normal workflow automatically
retains an APFS copy-on-write snapshot and a complete content-hash receipt.
Successful DMG upload removes only that job's snapshot; packaging failures
retain it outside the disposable runner. Snapshot maintenance is optional and
cannot invalidate an otherwise qualified release. If only packaging failed,
a signing-only validation can recover
that exact compilation rather than repeat the build:

```sh
gh workflow run build.yml --ref main \
  -f action=build -f runner_pool=private -f execution_profile=hybrid \
  -f mode=macos-validation -f build_version=3.0.3 \
  -f prepare_homebrew_cask=true -f macos_compilation_job_id=128247608189
```

`recover_macos_app.py` requires a successful native compile step in a completed
trusted-main release job, an owned retained snapshot, the same bundle version,
the immutable tag's exact compiled source, complete ancestry evidence and only
explicitly allowlisted packaging changes. It separately compares the Flutter
SDK, compiler settings and build command. It checks the complete copied app
tree and attests its compilation-recovery receipt. The fresh job still imports
the real signing identity, signs every nested component, notarizes the app,
verifies Gatekeeper acceptance, builds the DMG and signs its Sparkle update.
SDK and pub setup remain available for Sparkle; native compilation, CocoaPods
and NFS workspace preparation are skipped only for this validated recovery.

Before signing, `prepare_macos_app_for_signing.py` checks the complete owned
bundle boundary, makes build copies writable, removes recognized AppleDouble
sidecars left by NFS copies, and removes interrupted `.cstemp` signatures only
beside real Mach-O executables. Unknown files fail closed for inspection. Keep
the original retained compilation untouched. The helper writes a job-temporary
canonical entitlement plist, preserving effective values and rejecting
conflicting duplicate keys; AMFI rejects even identical duplicate XML keys.
Rehearse the complete nested-code
signing sequence and deep strict verification on an APFS clone before another
credentialed recovery attempt; checking only the first failed framework can
hide a later malformed nested bundle.

After the remaining original platforms and the Mac recovery succeed, finish
through the release controller instead of redispatching the full matrix:

```sh
python3 scripts/release_all_platforms.py --version 3.0.3 \
  --execution-profile hybrid --publish-github-only --prepare-homebrew-cask \
  --reuse-platform-run 42313043006 --reuse-macos-run MAC_RECOVERY_RUN_ID \
  --scratch /path/to/empty/task-scratch
```

The controller also reuses Android from that exact original run. The source
release must have successful iOS, tvOS, Windows x64/ARM64, Linux x64/ARM64,
Android, webOS and Tizen jobs, plus the complete exact-source CI result. Only
the original failed Mac packaging job may be replaced. The replacement requires
successful signature, notary, Gatekeeper, Sparkle and provenance-attestation
steps. Complete ancestry, pinned/compiler-input equivalence, GitHub artifact
digests and the recovered compilation receipt are checked again during final
assembly. The immutable tag stays on the compiled application source; the
published reuse receipt identifies the later packaging-workflow source.
Every platform remains required, including the verified original webOS IPK.

The macOS workflow validates its Developer ID identity, signs and verifies a
small native executable with Apple's timestamp service, and checks notary API
authentication immediately after checkout. These steps precede Flutter setup,
NFS source preparation, CocoaPods and application compilation. A certificate
or credential failure should take minutes rather than discard a completed
application build.

The job imports the checksum-pinned Apple Developer ID G2 intermediate into
its own temporary keychain. It selects the one valid identity for the configured
team and does not depend on an interactive login keychain or previous GUI use
of the CI account. Cleanup restores the original keychain search list, preserves
any later additions, and deletes only this job's keychain and credential files.
It also runs when signing fails before the NFS workspace exists.

The 3.0.3 attempt at `63f6d4ca4` compiled the application successfully but failed
at identity validation; the headless account also lacked the Developer ID
intermediate. Restoring the public intermediate repaired local certificate
chain verification; a successful full signing and notarization job remains
the authoritative check. Do not diagnose Flutter's log-forwarding process as
a stopped native compiler based on CPU use alone.

Use the low-level launcher only for a single-job recovery when no queue
controller is active for the run and no run-scoped Apple runner is online or
busy. Inspect queued Apple job IDs first:

```sh
run_id=YOUR_RUN_ID
gh api "repos/snapetech-org/pleazyng/actions/runs/$run_id/jobs?per_page=100" \
  | jq -r '.jobs[] | select(.status == "queued") | [.id,.name,(.labels|join(","))] | @tsv'
```

Start exactly one of the queued Apple jobs:

```sh
run_id=YOUR_RUN_ID
job_id=QUEUED_APPLE_JOB_ID
bash scripts/launch_apple_jit_runner.sh "$run_id" "$job_id"
```

The launcher checks that the job is queued and has the native Apple labels, that
there is no other run-scoped Apple JIT runner online or busy, that both NFS
mounts point to the same export, and that the Mac has at least 12 GiB free on
APFS and 40 GiB free on NFS. Flutter installation measures each download and
extraction peak, retaining 4 GiB locally plus 0.8 GiB for metadata; it does not
reserve an additional 30 GiB when the build workspace is on NFS.
It verifies the cached runner archive's SHA-256
before creating a unique per-run, per-job, per-attempt directory. The default
SSH target is the Mac's stable Tailscale address `keith@100.64.0.3`; override it
with `APPLE_JIT_SSH_TARGET` only if that identity changes.

The process must use `./run.sh --jitconfig <encoded-config>`. `config.sh` is for
persistent runner registration and does not start a JIT runner. The launcher
gets a single-use config from GitHub and streams it over SSH without printing
or saving it. On the Mac it starts from `/`, uses `sudo -H -u gha-jit-macos`,
sets `HOME=/Users/gha-jit-macos` and the system `PATH` explicitly, then keeps
the SSH session attached to `run.sh` until the job exits. Do not use `nohup` or
leave a detached runner behind. These details avoid the old prompt loop,
desktop-user HOME/PATH leakage, and macOS detach error.

Do not stop the persistent `/Users/ci-runner/actions-runner` service or restart
the broker to make room for an Apple JIT job. The JIT runner is separate from
that service and deregisters after its one job. If launch fails, the exact
run/job/attempt runner directory is retained for diagnosis; the launcher only
removes its own registration when GitHub shows it offline and not busy. Preserve
the runner logs and GitHub job logs before removing that exact task directory.

The queue controller performs the post-job checks and exact-path cleanup after
archiving evidence. In single-job troubleshooting mode, do those steps manually
before starting another job. Leave the runner cache, persistent service, NFS
mounts, and unrelated run directories in place.

## VPN and mount recovery after reboot

The host's launch daemon `com.snapetech.plezyng-native-build-nfs` runs every 60
seconds and installs the same export at both documented mount paths. Its
canonical helper is [`scripts/mount_macos_native_build_nfs.sh`](../../scripts/mount_macos_native_build_nfs.sh),
installed as `/usr/local/sbin/plezyng-native-build-mount.sh` with root ownership
and mode 755. Install a new copy atomically, then kickstart only this mount job.
Do not restart the runner broker or unmount a workspace in use.

The helper verifies MagicDNS, the expected client address on the tunnel route,
and ports 111/20048/2049. If needed it starts the existing saved Tailscale VPN
service with a bounded command. It preserves credentials, the VPN profile,
export permissions, and active mounts. Healthy connectivity does not depend on
the GUI app's CLI returning a status document: that CLI was observed hanging
while encrypted ping, SSH and NFS were already working.

For a stuck Connecting state, verify the actual tunnel before changing anything.
The November 5 recovery retained the existing VPN profile, refreshed only the
installed Tailscale app/extension registration, restarted those components and
started the saved VPN service. The recovered route answered a 3 ms ping and
NFS write/fsync/read validation. Preserve the diagnostics in private task
storage; do not delete keychains, authentication state or VPN profiles.
