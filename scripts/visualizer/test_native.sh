#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_output="$(mktemp -d "${TMPDIR:-/tmp}/plezy-visualizer-tests.XXXXXXXX")"
trap 'rm -rf -- "$test_output"' EXIT
for name in preset_transition native_worker render_thread legacy_image render_process; do
  "${CXX:-g++}" -std=c++17 -pthread \
    "$repo_root/test/native/visualizer_${name}_test.cc" -ldl \
    -o "$test_output/$name"
  "$test_output/$name"
done

# The worker includes the engine header. C++20 changes filesystem::u8string()
# to char8_t, so compile and run this existing test in both supported modes.
"${CXX:-g++}" -std=c++20 -pthread \
  "$repo_root/test/native/visualizer_native_worker_test.cc" -ldl \
  -o "$test_output/native_worker_cxx20"
"$test_output/native_worker_cxx20"
