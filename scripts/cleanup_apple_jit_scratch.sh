#!/usr/bin/env bash
set -euo pipefail

# A cancelled job can leave unobserved/reparented consumers. Retain its exact
# scratch without copying or deleting while the terminal launcher drains it.
if [[ "${APPLE_JIT_JOB_STATUS:-}" == cancelled ]]; then
  echo "Cancelled Apple job: retaining its build scratch and diagnostics."
  exit 0
fi

readonly NFS_MOUNT="/Volumes/p"
readonly NFS_RUNS_ROOT="$NFS_MOUNT/runs"

if [[ $# -ne 1 || ! "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "Usage: $0 <job-id>" >&2
  exit 2
fi
if [[ ! "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ || ! "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ ]]; then
  echo "GitHub run ID and attempt must be numeric." >&2
  exit 1
fi

scratch_job="$1"
task_root="$NFS_RUNS_ROOT/p${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${scratch_job}"
owner_file="$NFS_RUNS_ROOT/.plezyng-apple-scratch-p${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${scratch_job}.owner"

if [[ ! -e "$task_root" && ! -L "$task_root" && ! -e "$owner_file" && ! -L "$owner_file" ]]; then
  echo "No NFS Apple scratch to clean for run $GITHUB_RUN_ID attempt $GITHUB_RUN_ATTEMPT job $scratch_job."
  exit 0
fi
if [[ -L "$task_root" || ! -d "$task_root" || -L "$owner_file" || ! -f "$owner_file" ]]; then
  echo "Refusing to clean an incomplete or redirected Apple scratch pair: $task_root" >&2
  exit 1
fi
if [[ "$(cd "$task_root" && /bin/pwd -P)" != "$task_root" ]]; then
  echo "Refusing to clean an Apple scratch path that resolves elsewhere: $task_root" >&2
  exit 1
fi
if /usr/bin/grep -Fqx 'scratch_mode=local-xcode' "$owner_file"; then
  scratch_mode="local-xcode"
elif /usr/bin/grep -Fqx 'scratch_mode=nfs-derived-data' "$owner_file"; then
  scratch_mode="nfs-derived-data"
else
  echo "Refusing to clean Apple scratch with an unknown recorded mode: $owner_file" >&2
  exit 1
fi
for expected in \
  "run_id=$GITHUB_RUN_ID" \
  "run_attempt=$GITHUB_RUN_ATTEMPT" \
  "job=${GITHUB_JOB:-$scratch_job}" \
  "sha=${GITHUB_SHA:-}" \
  "scratch_mode=$scratch_mode" \
  "task_root=$task_root"; do
  if ! /usr/bin/grep -Fqx "$expected" "$owner_file"; then
    echo "Refusing to clean scratch without its matching owner record: $owner_file" >&2
    exit 1
  fi
done

if [[ -n "${APPLE_JIT_PROCESS_HELPER:-}" ]]; then
  if [[ -L "$APPLE_JIT_PROCESS_HELPER" || ! -f "$APPLE_JIT_PROCESS_HELPER" \
    || "$APPLE_JIT_PROCESS_HELPER" != "${APPLE_JIT_PROCESS_RUNNER_ROOT:-}/.apple-jit-process-tree.py" \
    || ! "${APPLE_JIT_PROCESS_JOB_ID:-}" =~ ^[0-9]+$ ]]; then
    echo "Refusing scratch cleanup with an unfamiliar process observer." >&2
    exit 1
  fi
  python3 "$APPLE_JIT_PROCESS_HELPER" assert-idle "$GITHUB_RUN_ID" \
    "$APPLE_JIT_PROCESS_JOB_ID" "$GITHUB_RUN_ATTEMPT" "$APPLE_JIT_PROCESS_RUNNER_ROOT"
fi

if /usr/bin/grep -Fqx 'scratch_mode=local-xcode' "$owner_file"; then
  if [[ -z "${RUNNER_TEMP:-}" || ! -d "$RUNNER_TEMP" ]]; then
    echo "RUNNER_TEMP is unavailable; refusing to remove local Xcode scratch." >&2
    exit 1
  fi
  runner_temp_real="$(cd "$RUNNER_TEMP" && /bin/pwd -P)"
  local_xcode_root="$runner_temp_real/pleazyng-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${scratch_job}-xcode"
  if ! /usr/bin/grep -Fqx "local_xcode_root=$local_xcode_root" "$owner_file"; then
    echo "Refusing to clean local Xcode scratch without its matching owner record: $local_xcode_root" >&2
    exit 1
  fi
  if [[ -L "$local_xcode_root" || ( -e "$local_xcode_root" && ! -d "$local_xcode_root" ) ]]; then
    echo "Refusing to clean redirected or non-directory local Xcode scratch: $local_xcode_root" >&2
    exit 1
  fi
  if [[ -d "$local_xcode_root" ]]; then
    if [[ "$(cd "$local_xcode_root" && /bin/pwd -P)" != "$local_xcode_root" ]]; then
      echo "Refusing to clean local Xcode scratch that resolves elsewhere: $local_xcode_root" >&2
      exit 1
    fi
    /bin/rm -rf -- "$local_xcode_root"
  fi
fi

/bin/rm -rf -- "$task_root"
/bin/rm -f -- "$owner_file"
echo "Removed task-owned NFS Apple scratch: $task_root"
