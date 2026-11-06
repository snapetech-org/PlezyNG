#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
kotlinc \
  "$root/packages/background_downloader/android/src/main/kotlin/com/bbflight/background_downloader/DownloadStorageGuard.kt" \
  "$root/test/native/download_storage_guard_test.kt" \
  -include-runtime -d "$test_dir/storage-guard.jar"
java -jar "$test_dir/storage-guard.jar"
