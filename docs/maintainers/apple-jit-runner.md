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

Swift package resolution also uses the job's local APFS DerivedData path.
It must not fall back to `~/Library/Developer/Xcode/DerivedData`, where aborted
jobs previously left build output outside the runner cleanup root.
The launcher also checks default Xcode DerivedData workspace records after the
job exits. It archives matching logs (and all build products after failure),
then removes only output belonging to that run and attempt. Other workspaces
and shared caches remain available.

The build-only NFS export on kspld0 is configured in
`/etc/exports.d/plezyng-mpv-build.exports`. Keep its reproducible scratch data on
`async` writes; `sync` made metadata-heavy workspace copies, Git checkouts and
DMG staging take many minutes. The authorized Mac client remains its stable
Tailscale IP `100.64.0.3`, so DHCP LAN address changes do not alter access. Preserve
all client, ownership and root-squash options. Update only this export with
`exportfs -i -o` using the complete existing option list; do not restart active
runners or reload unrelated exports. This scratch policy permits write
acknowledgement before stable storage and is not a policy for personal data.

Steam sources prepared under `.dart_tool/games/steam` are reusable between
Apple platforms when `.plezy-recipe` matches the script, source lock and patches.
Preserve a completed source cache before removing the creating workspace,
record its archive digest and source run, then restore it into a later task
workspace before its source-preparation consumer starts. Verify the task owner,
source SHA and recipe; leave an already-started preparation untouched. Compiled
archives remain architecture-specific.

## Single-job troubleshooting

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
mounts point to the same export, and that the Mac has at least 37 GiB free on
APFS and 40 GiB free on NFS. It verifies the cached runner archive's SHA-256
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
