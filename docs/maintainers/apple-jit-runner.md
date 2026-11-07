# PlezyNG Apple JIT runner

The iOS, tvOS, and macOS release jobs target the `private-apple-builds` runner
group. This lane has one private Mac slot, so only one of these jobs can run at
a time. A queued Apple job is waiting for that slot; it is not blocked by the
other platform builds. Linux, Android, Tizen, and Windows jobs remain eligible
to run concurrently on their selected hosted runners.

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

## Single-job troubleshooting

### Check signing before compiling macOS

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
gh api "repos/snapetech-org/PlezyNG/actions/runs/$run_id/jobs?per_page=100" \
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
