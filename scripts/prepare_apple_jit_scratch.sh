#!/usr/bin/env bash
set -euo pipefail

readonly NFS_MOUNT="/Volumes/plezyng-native-build-kspld0"
readonly NFS_RUNS_ROOT="$NFS_MOUNT/runs"

usage() {
  echo "Usage: $0 <job-id> <minimum-free-gib> [nfs-derived-data|local-derived-data]" >&2
  exit 2
}

[[ $# -ge 2 && $# -le 3 ]] || usage
scratch_job="$1"
minimum_free_gib="$2"
scratch_mode="${3:-nfs-derived-data}"

if [[ "${RUNNER_OS:-}" != "macOS" ]]; then
  echo "Apple JIT scratch setup requires a macOS private runner." >&2
  exit 1
fi
if [[ ! "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ || ! "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ ]]; then
  echo "GitHub run ID and attempt must be numeric." >&2
  exit 1
fi
if [[ ! "$scratch_job" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "Invalid Apple scratch job identifier: $scratch_job" >&2
  exit 1
fi
if [[ ! "$minimum_free_gib" =~ ^[1-9][0-9]*$ ]]; then
  echo "Minimum free-space requirement must be a positive whole GiB value." >&2
  exit 1
fi
if [[ "$scratch_mode" != "nfs-derived-data" && "$scratch_mode" != "local-derived-data" ]]; then
  echo "Unsupported Apple scratch mode: $scratch_mode" >&2
  exit 1
fi
if [[ -z "${GITHUB_SHA:-}" || -z "${GITHUB_ENV:-}" || ! -w "$GITHUB_ENV" ]]; then
  echo "GitHub SHA and a writable GITHUB_ENV are required." >&2
  exit 1
fi
if [[ ! -d "$NFS_RUNS_ROOT" || -L "$NFS_RUNS_ROOT" ]]; then
  echo "The NFS run-scratch directory is missing or is a symlink: $NFS_RUNS_ROOT" >&2
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

free_kib="$(/bin/df -Pk "$NFS_RUNS_ROOT" | /usr/bin/awk 'NR == 2 { print $4 }')"
if [[ ! "$free_kib" =~ ^[0-9]+$ ]]; then
  echo "Could not measure NFS free space at $NFS_RUNS_ROOT." >&2
  /bin/df -h "$NFS_RUNS_ROOT" >&2
  exit 1
fi
minimum_free_kib=$((minimum_free_gib * 1024 * 1024))
if (( free_kib < minimum_free_kib )); then
  echo "Apple JIT scratch needs ${minimum_free_gib} GiB free on NFS before starting." >&2
  /bin/df -h "$NFS_RUNS_ROOT" >&2
  exit 1
fi

task_root="$NFS_RUNS_ROOT/p${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${scratch_job}"
owner_file="$NFS_RUNS_ROOT/.plezyng-apple-scratch-p${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${scratch_job}.owner"
local_xcode_root=""
if [[ "$scratch_mode" == "local-derived-data" ]]; then
  if [[ -z "${RUNNER_TEMP:-}" || ! -d "$RUNNER_TEMP" ]]; then
    echo "A real RUNNER_TEMP directory is required for local Xcode DerivedData." >&2
    exit 1
  fi
  runner_temp_real="$(cd "$RUNNER_TEMP" && /bin/pwd -P)"
  local_xcode_root="$runner_temp_real/plezyng-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${scratch_job}-xcode"
fi
if (( ${#task_root} > 64 )); then
  echo "NFS Apple workspace path is unexpectedly long (${#task_root} characters): $task_root" >&2
  exit 1
fi
if [[ -e "$task_root" || -L "$task_root" || -e "$owner_file" || -L "$owner_file" || ( -n "$local_xcode_root" && ( -e "$local_xcode_root" || -L "$local_xcode_root" ) ) ]]; then
  echo "Refusing to reuse existing Apple JIT scratch paths: $task_root ${local_xcode_root:+and $local_xcode_root}" >&2
  exit 1
fi

created_root=0
created_owner=0
created_local_xcode_root=0
cleanup_partial() {
  local status=$?
  trap - EXIT
  if (( created_local_xcode_root )) && [[ -n "$local_xcode_root" && -d "$local_xcode_root" && ! -L "$local_xcode_root" ]]; then
    /bin/rm -rf -- "$local_xcode_root"
  fi
  if (( created_root )) && [[ "$task_root" == "$NFS_RUNS_ROOT/p${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${scratch_job}" && -d "$task_root" && ! -L "$task_root" ]]; then
    /bin/rm -rf -- "$task_root"
  fi
  if (( created_owner )) && [[ "$owner_file" == "$NFS_RUNS_ROOT/.plezyng-apple-scratch-p${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${scratch_job}.owner" && -f "$owner_file" && ! -L "$owner_file" ]]; then
    /bin/rm -f -- "$owner_file"
  fi
  exit "$status"
}
trap cleanup_partial EXIT

umask 077
/bin/mkdir -m 700 "$task_root"
created_root=1
if [[ -n "$local_xcode_root" ]]; then
  /bin/mkdir -m 700 "$local_xcode_root"
  created_local_xcode_root=1
fi
{
  printf 'run_id=%s\n' "$GITHUB_RUN_ID"
  printf 'run_attempt=%s\n' "$GITHUB_RUN_ATTEMPT"
  printf 'job=%s\n' "${GITHUB_JOB:-$scratch_job}"
  printf 'sha=%s\n' "$GITHUB_SHA"
  printf 'scratch_mode=%s\n' "$scratch_mode"
  printf 'task_root=%s\n' "$task_root"
  printf 'local_xcode_root=%s\n' "$local_xcode_root"
} > "$owner_file"
created_owner=1

probe_dir="$task_root/.nfs-probe"
/bin/mkdir -m 700 "$probe_dir"
/usr/bin/printf 'PlezyNG Apple JIT NFS scratch probe\n' > "$probe_dir/probe.bin"
/bin/chmod 640 "$probe_dir/probe.bin"
/bin/mv "$probe_dir/probe.bin" "$probe_dir/renamed.bin"
/bin/ln -s renamed.bin "$probe_dir/link"
/usr/bin/cmp "$probe_dir/renamed.bin" "$probe_dir/link"
/usr/bin/shasum -a 256 "$probe_dir/renamed.bin" >/dev/null
/bin/rm -rf -- "$probe_dir"

{
  printf 'PLEZYNG_APPLE_TASK_ROOT=%s\n' "$task_root"
  printf 'PLEZYNG_APPLE_TASK_OWNER_FILE=%s\n' "$owner_file"
  printf 'PLEZYNG_APPLE_WORKSPACE=%s\n' "$task_root"
  printf 'APPLE_SOURCE_PACKAGES_DIR=%s/build/%s/SourcePackages\n' "$task_root" "$scratch_job"
  if [[ -n "$local_xcode_root" ]]; then
    printf 'APPLE_DERIVED_DATA_PATH=%s/DerivedData\n' "$local_xcode_root"
    printf 'APPLE_RESULT_BUNDLE=%s/apple-native-reliability.xcresult\n' "$local_xcode_root"
  else
    printf 'APPLE_DERIVED_DATA_PATH=%s/DerivedData\n' "$task_root"
    printf 'APPLE_RESULT_BUNDLE=%s/apple-native-reliability.xcresult\n' "$task_root"
  fi
} >> "$GITHUB_ENV"

trap - EXIT
if [[ -n "$local_xcode_root" ]]; then
  echo "Prepared private per-run Apple scratch: Swift packages on NFS at $task_root; Xcode DerivedData and results on local APFS at $local_xcode_root." >&2
else
  echo "Prepared private per-run Apple scratch on NFS: $task_root (${#task_root} characters; ${minimum_free_gib} GiB minimum)." >&2
fi
printf '%s\n' "$task_root"
