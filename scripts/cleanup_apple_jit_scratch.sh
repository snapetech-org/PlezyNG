#!/usr/bin/env bash
set -euo pipefail

readonly NFS_MOUNT="/Volumes/plezyng-native-build-kspld0"
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
for expected in \
  "run_id=$GITHUB_RUN_ID" \
  "run_attempt=$GITHUB_RUN_ATTEMPT" \
  "job=${GITHUB_JOB:-$scratch_job}" \
  "sha=${GITHUB_SHA:-}" \
  "task_root=$task_root"; do
  if ! /usr/bin/grep -Fqx "$expected" "$owner_file"; then
    echo "Refusing to clean scratch without its matching owner record: $owner_file" >&2
    exit 1
  fi
done

/bin/rm -rf -- "$task_root"
/bin/rm -f -- "$owner_file"
echo "Removed task-owned NFS Apple scratch: $task_root"
