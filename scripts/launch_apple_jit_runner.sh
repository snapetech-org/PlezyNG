#!/usr/bin/env bash
set -euo pipefail

readonly ORG="snapetech-org"
readonly REPO="PlezyNG"
readonly RUNNER_GROUP_ID="${APPLE_JIT_RUNNER_GROUP_ID:-8}"
readonly SSH_TARGET="${APPLE_JIT_SSH_TARGET:-keith@100.64.0.3}"
readonly SERVICE_USER="gha-jit-macos"
readonly SERVICE_HOME="/Users/gha-jit-macos"
readonly RUNS_ROOT="$SERVICE_HOME/Library/Caches/gha-jit-macos/runs"
readonly CACHE_PATH="${APPLE_JIT_RUNNER_CACHE:-$SERVICE_HOME/Library/Caches/gha-jit-macos/runner-cache/actions-runner-osx-arm64-2.338.0.tar.gz}"
readonly CACHE_SHA256="${APPLE_JIT_RUNNER_CACHE_SHA256:-df4cebda25c86a886ed204e49fee63f5c2e7cec5f447b5c98440a826bbdf9df2}"
readonly REMOTE_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

usage() {
  echo "Usage: $0 <workflow-run-id> <queued-apple-job-id>" >&2
  echo "Starts exactly one queued PlezyNG Apple JIT job and stays attached until it exits." >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
run_id="$1"
job_id="$2"
[[ "$run_id" =~ ^[0-9]+$ && "$job_id" =~ ^[0-9]+$ ]] || usage

for command in gh jq ssh; do
  command -v "$command" >/dev/null || { echo "Required command not found: $command" >&2; exit 1; }
done

readonly API_ROOT="/orgs/$ORG/actions"
readonly RUN_URL="repos/$ORG/$REPO/actions/runs/$run_id"
run_json="$(gh api "$RUN_URL")"
run_status="$(jq -r '.status' <<<"$run_json")"
run_attempt="$(jq -er '.run_attempt | select(type == "number")' <<<"$run_json")"
if [[ "$(jq -r '.event' <<<"$run_json")" != workflow_dispatch \
  || "$(jq -r '.head_branch' <<<"$run_json")" != main \
  || "$(jq -r '.head_repository.full_name' <<<"$run_json")" != "$ORG/$REPO" ]]; then
  echo "Only trusted-main PlezyNG workflow_dispatch runs may use the private Apple lane." >&2
  exit 1
fi
run_root="$RUNS_ROOT/$run_id-$job_id-attempt$run_attempt"
runner_root="$run_root/runner"
if [[ "$run_status" != queued && "$run_status" != in_progress ]]; then
  echo "Run $run_id is $run_status; refusing to add a runner." >&2
  exit 1
fi

jobs_json="$(gh api "$RUN_URL/jobs?per_page=100")"
job_json="$(jq -ce --argjson id "$job_id" '[.jobs[] | select(.id == $id)] | if length == 1 then .[0] else error("job not found or ambiguous") end' <<<"$jobs_json")"
if [[ "$(jq -r '.status' <<<"$job_json")" != queued ]]; then
  echo "Job $job_id is $(jq -r '.status' <<<"$job_json"); only queued jobs can be provisioned." >&2
  exit 1
fi

labels_json="$(jq -c '.labels' <<<"$job_json")"
jq -e 'index("private-apple") and index("macOS") and index("ARM64")' <<<"$labels_json" >/dev/null || {
  echo "Job $job_id is not assigned to the native private Apple runner route." >&2
  exit 1
}
runner_labels="$(jq -c --arg prefix "gha-$run_id-" '[.[] | select(startswith($prefix))]' <<<"$labels_json")"
if [[ "$(jq 'length' <<<"$runner_labels")" -ne 1 ]]; then
  echo "Job $job_id does not have exactly one run-scoped gha-* label." >&2
  exit 1
fi
runner_name="$(jq -r '.[0]' <<<"$runner_labels")"

# The Mac is a one-job lane. Do not create a second runner while any run-scoped
# Apple JIT is online or busy, even if GitHub's job list still says queued.
group_json="$(gh api "$API_ROOT/runner-groups/$RUNNER_GROUP_ID/runners?per_page=100")"
if jq -e --arg name "$runner_name" 'any(.runners[]; .name == $name)' <<<"$group_json" >/dev/null; then
  echo "Runner $runner_name already exists; inspect its live state before retrying." >&2
  exit 1
fi
active_apple="$(jq -r '[.runners[] | select((.labels | any(.name == "private-apple")) and (.labels | any(.name | startswith("ng-main-run-"))) and (.status == "online" or .busy == true))] | length' <<<"$group_json")"
if [[ "$active_apple" != 0 ]]; then
  echo "A run-scoped Apple JIT runner is already online or busy; keep this job queued." >&2
  exit 1
fi

# Check disk, both NFS mounts, and the pinned runner cache before consuming a
# one-time JIT configuration. The SSH command starts from / so sudo never
# inherits the desktop user's inaccessible working directory.
ssh -T -o BatchMode=yes -o ConnectTimeout=8 "$SSH_TARGET" \
  "cd / && sudo -H -u $SERVICE_USER env HOME=$SERVICE_HOME PATH=$REMOTE_PATH /bin/bash -s" <<REMOTE_PREFLIGHT
set -euo pipefail
unset BASH_ENV ENV CDPATH
readonly SERVICE_HOME="$SERVICE_HOME"
readonly CACHE_PATH="$CACHE_PATH"
readonly CACHE_SHA256="$CACHE_SHA256"
readonly RUN_ROOT="$run_root"
[[ "\$HOME" == "\$SERVICE_HOME" ]]
[[ "\$PATH" == "$REMOTE_PATH" ]]
[[ ! -e "\$RUN_ROOT" && ! -L "\$RUN_ROOT" ]]

free_kib="\$(/bin/df -Pk / | /usr/bin/awk 'NR == 2 {print \$4}')"
(( free_kib >= 38 * 1024 * 1024 )) || { echo "Apple JIT needs at least 38 GiB free on local APFS." >&2; /bin/df -h / >&2; exit 1; }
[[ -d /Volumes/p/runs && ! -L /Volumes/p/runs ]]
[[ -d /Volumes/plezyng-native-build-kspld0 ]]
short_mount="\$(/sbin/mount | /usr/bin/awk '\$3 == "/Volumes/p" {print; exit}')"
primary_mount="\$(/sbin/mount | /usr/bin/awk '\$3 == "/Volumes/plezyng-native-build-kspld0" {print; exit}')"
short_source="\$(/usr/bin/awk '{print \$1}' <<<"\$short_mount")"
primary_source="\$(/usr/bin/awk '{print \$1}' <<<"\$primary_mount")"
case "\$short_mount" in kspld0*:/mnt/disks/gamespool0/plezyng-native-build-*" on /Volumes/p (nfs,"*) ;; *) echo "Unexpected NFS mount at /Volumes/p: \$short_mount" >&2; exit 1 ;; esac
[[ "\$short_source" == "\$primary_source" ]] || { echo "The two Apple NFS paths do not reference the same export." >&2; exit 1; }
nfs_free_kib="\$(/bin/df -Pk /Volumes/p/runs | /usr/bin/awk 'NR == 2 {print \$4}')"
(( nfs_free_kib >= 40 * 1024 * 1024 )) || { echo "Apple JIT needs at least 40 GiB free on NFS." >&2; /bin/df -h /Volumes/p/runs >&2; exit 1; }
cache_sha="\$(/usr/bin/shasum -a 256 "\$CACHE_PATH" | /usr/bin/awk '{print \$1}')"
[[ "\$cache_sha" == "\$CACHE_SHA256" ]] || { echo "Pinned Apple runner cache checksum mismatch." >&2; exit 1; }
listeners="\$(/bin/ps -Ao user=,comm= | /usr/bin/awk '\$1 == "gha-jit-macos" && \$2 == "Runner.Listener" {n++} END {print n+0}')"
[[ "\$listeners" == 0 ]] || { echo "A runner listener is already active as gha-jit-macos." >&2; exit 1; }
/bin/df -h / /Volumes/p/runs
printf 'Apple JIT preflight passed; runner cache SHA-256 verified.\\n'
REMOTE_PREFLIGHT

request_body="$(jq -cn --arg name "$runner_name" --argjson group "$RUNNER_GROUP_ID" --argjson labels "$labels_json" '{name:$name,runner_group_id:$group,labels:$labels,work_folder:"_work"}')"
jit_config="$(printf '%s' "$request_body" | gh api --method POST "$API_ROOT/runners/generate-jitconfig" --input - --jq .encoded_jit_config)"
[[ -n "$jit_config" ]] || { echo "GitHub returned an empty JIT configuration." >&2; exit 1; }
runner_registration_created=1

cleanup_offline_registration() {
  local exit_status=$?
  trap - EXIT
  if (( exit_status != 0 && runner_registration_created == 1 )); then
    local runners_json runner_json runner_id runner_status runner_busy
    if runners_json="$(gh api "$API_ROOT/runner-groups/$RUNNER_GROUP_ID/runners?per_page=100" 2>/dev/null)"; then
      runner_json="$(jq -c --arg name "$runner_name" '[.runners[] | select(.name == $name)] | if length == 1 then .[0] else empty end' <<<"$runners_json")"
      if [[ -n "$runner_json" ]]; then
        runner_id="$(jq -r '.id' <<<"$runner_json")"
        runner_status="$(jq -r '.status' <<<"$runner_json")"
        runner_busy="$(jq -r '.busy' <<<"$runner_json")"
        if [[ "$runner_status" == offline && "$runner_busy" == false ]]; then
          gh api --method DELETE "$API_ROOT/runners/$runner_id" >/dev/null 2>&1 || true
          echo "Removed this launch's offline JIT registration $runner_id; retained runner files at $runner_root." >&2
        else
          echo "Runner $runner_name is $runner_status (busy=$runner_busy); leaving its registration and files intact." >&2
        fi
      fi
    fi
  fi
  exit "$exit_status"
}
trap cleanup_offline_registration EXIT

{
  printf 'JIT_CONFIG=%q\n' "$jit_config"
  printf 'RUN_ROOT=%q\n' "$run_root"
  printf 'RUNNER_ROOT=%q\n' "$runner_root"
  printf 'RUNNER_NAME=%q\n' "$runner_name"
  printf 'JOB_ID=%q\n' "$job_id"
  printf 'CACHE_PATH=%q\n' "$CACHE_PATH"
  printf 'CACHE_SHA256=%q\n' "$CACHE_SHA256"
  cat <<'REMOTE_LAUNCH'
set -euo pipefail
unset BASH_ENV ENV CDPATH
[[ "$HOME" == /Users/gha-jit-macos ]]
[[ "$PATH" == /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin ]]
[[ "$RUN_ROOT" == /Users/gha-jit-macos/Library/Caches/gha-jit-macos/runs/* ]]
[[ "$RUNNER_ROOT" == "$RUN_ROOT/runner" ]]
[[ -f "$CACHE_PATH" && ! -L "$CACHE_PATH" ]]
actual="$(/usr/bin/shasum -a 256 "$CACHE_PATH" | /usr/bin/awk '{print $1}')"
[[ "$actual" == "$CACHE_SHA256" ]]
[[ ! -e "$RUN_ROOT" && ! -L "$RUN_ROOT" ]]
/bin/mkdir -m 700 -p "$RUN_ROOT"
/bin/mkdir -m 700 "$RUNNER_ROOT"
/usr/bin/tar -xzf "$CACHE_PATH" -C "$RUNNER_ROOT"
[[ -x "$RUNNER_ROOT/run.sh" ]]
cd "$RUNNER_ROOT"
/usr/bin/printf '%s\n' "$$" > "$RUNNER_ROOT/launcher.pid"
printf 'Starting %s for queued job %s. Runner logs will stay attached to this SSH session.\n' "$RUNNER_NAME" "$JOB_ID"
exec ./run.sh --jitconfig "$JIT_CONFIG"
REMOTE_LAUNCH
} | ssh -T -o BatchMode=yes -o ConnectTimeout=8 "$SSH_TARGET" \
  "cd / && sudo -H -u $SERVICE_USER env HOME=$SERVICE_HOME PATH=$REMOTE_PATH /bin/bash -s"

job_after=""
for _ in {1..60}; do
  job_after="$(gh api "$RUN_URL/jobs?per_page=100" | jq -ce --argjson id "$job_id" '[.jobs[] | select(.id == $id)] | if length == 1 then .[0] else error("job not found or ambiguous") end')"
  [[ "$(jq -r '.status' <<<"$job_after")" == completed ]] && break
  sleep 2
done
if [[ "$(jq -r '.status' <<<"$job_after")" != completed ]]; then
  echo "Runner exited, but job $job_id has not completed; retain its runner root for diagnosis." >&2
  echo "Runner root: $runner_root" >&2
  exit 1
fi
conclusion="$(jq -r '.conclusion' <<<"$job_after")"
if [[ -n "${APPLE_JIT_EVIDENCE_DIR:-}" ]]; then
  printf 'Job %s completed with conclusion: %s\nArchiving diagnostics before exact-path cleanup: %s\n' \
    "$job_id" "$conclusion" "$runner_root"
else
  printf 'Job %s completed with conclusion: %s\nRunner root retained for diagnostics: %s\n' \
    "$job_id" "$conclusion" "$runner_root"
fi

# The queue controller supplies an evidence directory. In that mode, preserve
# the runner diagnostics, verify the one-job registration has deregistered, and
# clean only this completed run/job/attempt directory so the next Apple job can
# use the same Mac slot without manual cleanup.
if [[ -n "${APPLE_JIT_EVIDENCE_DIR:-}" ]]; then
  evidence_dir="${APPLE_JIT_EVIDENCE_DIR%/}"
  [[ "$evidence_dir" == /* && ! -L "$evidence_dir" ]]
  /bin/mkdir -m 700 -p "$evidence_dir"
  /bin/chmod 700 "$evidence_dir"
  diag_archive="$evidence_dir/${run_id}-${job_id}-attempt${run_attempt}-runner-diag.tar.gz"
  [[ ! -e "$diag_archive" && ! -L "$diag_archive" ]] || {
    echo "Refusing to overwrite runner diagnostics: $diag_archive" >&2
    exit 1
  }

  registration_gone=0
  for _ in {1..30}; do
    group_json="$(gh api "$API_ROOT/runner-groups/$RUNNER_GROUP_ID/runners?per_page=100")"
    if ! jq -e --arg name "$runner_name" 'any(.runners[]; .name == $name)' <<<"$group_json" >/dev/null; then
      registration_gone=1
      break
    fi
    sleep 1
  done
  if (( registration_gone == 0 )); then
    echo "Runner registration $runner_name remains after job completion; keeping $run_root for diagnosis." >&2
    exit 1
  fi

  ssh -T -o BatchMode=yes -o ConnectTimeout=8 "$SSH_TARGET" \
    "cd / && sudo -H -u $SERVICE_USER env HOME=$SERVICE_HOME PATH=$REMOTE_PATH /bin/bash -s" \
    <<<"set -euo pipefail; /usr/bin/tar -czf - -C '$runner_root' _diag" > "$diag_archive"
  [[ -s "$diag_archive" ]]
  /usr/bin/tar -tzf "$diag_archive" >/dev/null
  /bin/chmod 600 "$diag_archive"
  diag_sha256="$(/usr/bin/sha256sum "$diag_archive" | /usr/bin/awk '{print $1}')"
  printf 'Saved runner diagnostics: %s (sha256 %s)\n' "$diag_archive" "$diag_sha256"

  ssh -T -o BatchMode=yes -o ConnectTimeout=8 "$SSH_TARGET" \
    "cd / && sudo -H -u $SERVICE_USER env HOME=$SERVICE_HOME PATH=$REMOTE_PATH /bin/bash -s" <<REMOTE_CLEAN
set -euo pipefail
readonly RUN_ROOT="$run_root"
readonly RUNS_ROOT="$RUNS_ROOT"
readonly RUNNER_ROOT="$runner_root"
[[ "\$RUN_ROOT" == "\$RUNS_ROOT/$run_id-$job_id-attempt$run_attempt" ]]
[[ -d "\$RUN_ROOT" && ! -L "\$RUN_ROOT" ]]
[[ -d "\$RUNNER_ROOT/_diag" && ! -L "\$RUNNER_ROOT" ]]
listeners="\$(/bin/ps -U "$SERVICE_USER" -o comm= | /usr/bin/grep -F -c "\$RUNNER_ROOT/bin/Runner.Listener" || true)"
[[ "\$listeners" == 0 ]]
/usr/bin/python3 - "\$RUN_ROOT" "\$RUNS_ROOT" "$run_id" "$job_id" "$run_attempt" <<'PY'
from pathlib import Path
import os
import shutil
import sys

run_root = Path(sys.argv[1])
runs_root = Path(sys.argv[2])
expected = runs_root / f"{sys.argv[3]}-{sys.argv[4]}-attempt{sys.argv[5]}"
if run_root != expected or run_root.is_symlink() or not run_root.is_dir():
    raise SystemExit("Refusing to remove a runner directory outside this completed job.")
if run_root.stat().st_uid != os.geteuid():
    raise SystemExit("Refusing to remove a runner directory not owned by the JIT service user.")
if (run_root / "runner").is_symlink() or not (run_root / "runner/_diag").is_dir():
    raise SystemExit("Refusing to remove a runner directory without archived diagnostics.")
shutil.rmtree(run_root)
PY
[[ ! -e "\$RUN_ROOT" && ! -L "\$RUN_ROOT" ]]
printf 'Removed completed one-job runner directory: %s\n' "$run_root"
REMOTE_CLEAN
fi

[[ "$conclusion" == success ]]
