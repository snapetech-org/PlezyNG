# PlezyNG Apple JIT runner

The iOS, tvOS, and macOS release jobs target the `private-apple-builds` runner
group. This lane has one private Mac slot, so only one of these jobs can run at
a time. A queued Apple job is waiting for that slot; it is not blocked by the
other platform builds. Linux, Android, Tizen, and Windows jobs remain eligible
to run concurrently on their selected hosted runners.

## Start one queued Apple job

Inspect the queued job IDs for the active run:

```sh
run_id=YOUR_RUN_ID
gh api "repos/snapetech-org/PlezyNG/actions/runs/$run_id/jobs?per_page=100" \
  | jq -r '.jobs[] | select(.status == "queued") | [.id,.name,(.labels|join(","))] | @tsv'
```

Start exactly one of the queued `build-ios`, `build-tvos`, or `build-macos` jobs:

```sh
run_id=YOUR_RUN_ID
job_id=QUEUED_APPLE_JOB_ID
bash scripts/launch_apple_jit_runner.sh "$run_id" "$job_id"
```

The launcher checks that the job is queued and has the native Apple labels, that
there is no other run-scoped Apple JIT runner online or busy, that both NFS
mounts point to the same export, and that the Mac has at least 38 GiB free on
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

After a job completes, let `run.sh` exit and confirm the job is completed and
its JIT registration is gone before starting the next Apple job. Keep the
workflow logs and `_diag` evidence under task scratch; remove only the exact
run/job/attempt directory after copying the evidence. Leave the runner cache,
the persistent service, NFS mounts, and unrelated run directories in place.
