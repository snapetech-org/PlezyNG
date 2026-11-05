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
