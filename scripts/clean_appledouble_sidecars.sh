#!/usr/bin/env bash
set -euo pipefail

readonly NFS_MOUNT="/Volumes/plezyng-native-build-kspld0"
readonly NFS_RUNS_ROOT="$NFS_MOUNT/runs"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <task-owned-apple-workspace>" >&2
  exit 2
fi
if [[ "${RUNNER_OS:-}" != "macOS" ]]; then
  echo "AppleDouble cleanup requires a macOS private runner." >&2
  exit 1
fi
if [[ ! "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ || ! "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ ]]; then
  echo "GitHub run ID and attempt must be numeric." >&2
  exit 1
fi

case "${GITHUB_JOB:-}" in
  build-ios) scratch_job="ios" ;;
  build-macos) scratch_job="macos" ;;
  *)
    echo "AppleDouble cleanup is not configured for this job: ${GITHUB_JOB:-unset}" >&2
    exit 1
    ;;
esac

task_root="$NFS_RUNS_ROOT/p${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${scratch_job}"
owner_file="$NFS_RUNS_ROOT/.plezyng-apple-scratch-p${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${scratch_job}.owner"
workspace="$1"
if [[ "$workspace" != "$task_root" || -L "$workspace" || ! -d "$workspace" ]]; then
  echo "Refusing to clean an unexpected or redirected Apple workspace: $workspace" >&2
  exit 1
fi
if [[ "$(cd "$workspace" && /bin/pwd -P)" != "$task_root" ]]; then
  echo "Refusing to clean an Apple workspace that resolves elsewhere: $workspace" >&2
  exit 1
fi
if [[ -L "$owner_file" || ! -f "$owner_file" ]]; then
  echo "Refusing to clean Apple workspace without its task owner record: $owner_file" >&2
  exit 1
fi

mount_line="$(/sbin/mount | /usr/bin/awk -v mountpoint="$NFS_MOUNT" '$3 == mountpoint { print; exit }')"
case "$mount_line" in
  kspld0*:/mnt/disks/gamespool0/plezyng-native-build-*" on $NFS_MOUNT (nfs,"*) ;;
  *)
    echo "Expected the PlezyNG NFS export from kspld0 at $NFS_MOUNT; found: ${mount_line:-no mount}" >&2
    exit 1
    ;;
esac

for expected in \
  "run_id=$GITHUB_RUN_ID" \
  "run_attempt=$GITHUB_RUN_ATTEMPT" \
  "job=$GITHUB_JOB" \
  "sha=${GITHUB_SHA:-}" \
  "scratch_mode=local-xcode" \
  "task_root=$task_root"; do
  if ! /usr/bin/grep -Fqx "$expected" "$owner_file"; then
    echo "Refusing to clean Apple workspace without its matching owner record: $owner_file" >&2
    exit 1
  fi
done

before_count="$(/usr/bin/find "$task_root" -name '._*' -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
if [[ "$before_count" != "0" ]]; then
  echo "Deleting $before_count AppleDouble sidecars from task-owned source workspace: $task_root"
  /usr/bin/find "$task_root" -type f -name '._*' -delete
fi

remaining="$(/usr/bin/find "$task_root" -name '._*' -print -quit)"
if [[ -n "$remaining" ]]; then
  echo "AppleDouble sidecars remain after cleanup; refusing to run Xcode. First remaining paths:" >&2
  /usr/bin/find "$task_root" -name '._*' -print | /usr/bin/sed -n '1,20p' >&2
  exit 1
fi

echo "AppleDouble sidecar check passed for task-owned source workspace: $task_root"
