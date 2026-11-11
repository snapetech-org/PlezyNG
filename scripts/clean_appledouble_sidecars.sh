#!/usr/bin/env bash
set -euo pipefail

readonly NFS_MOUNT="/Volumes/p"
readonly NFS_RUNS_ROOT="$NFS_MOUNT/runs"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <task-owned-apple-workspace>" >&2
  exit 2
fi
if [[ "${RUNNER_OS:-}" != "macOS" ]]; then
  echo "AppleDouble cleanup requires a macOS runner." >&2
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

workspace="$1"
if [[ "${RUNNER_ENVIRONMENT:-}" == "github-hosted" ]]; then
  if [[ -z "${RUNNER_TEMP:-}" || ! -d "$RUNNER_TEMP" ]]; then
    echo "Hosted AppleDouble cleanup requires a real RUNNER_TEMP." >&2
    exit 1
  fi
  runner_temp_real="$(cd "$RUNNER_TEMP" && /bin/pwd -P)"
  task_root="$runner_temp_real/p${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${scratch_job}"
  if [[ "$workspace" != "$task_root" || -L "$workspace" || ! -d "$workspace" || "$(cd "$workspace" && /bin/pwd -P)" != "$task_root" ]]; then
    echo "Refusing to clean an unexpected or redirected hosted Apple workspace: $workspace" >&2
    exit 1
  fi
else
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
      echo "Expected the Pleazyng NFS export from kspld0 at $NFS_MOUNT; found: ${mount_line:-no mount}" >&2
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
fi


# Workflow ownership retains GITHUB_SHA; an approved frozen repair may check out
# a different, independently verified packaging source. Never conflate the two.
source_sha="${COMPILE_SOURCE_SHA:-${GITHUB_SHA:-}}"
if [[ ! "$source_sha" =~ ^[0-9a-f]{40}$ || "$(git -C "$workspace" rev-parse HEAD)" != "$source_sha" ]]; then
  echo "Apple workspace does not contain the exact requested source revision." >&2
  exit 1
fi

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
