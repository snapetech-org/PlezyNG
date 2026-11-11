#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_output="$(mktemp -d "${TMPDIR:-/tmp}/plezy-visualizer-tests.XXXXXXXX")"
trap 'rm -rf -- "$test_output"' EXIT
# C++20 changes filesystem UTF-8 strings and is used by the Windows runner.
# Exercise every shared backend/protocol header in both supported modes.
for standard in c++17 c++20; do
  for name in preset_transition native_worker render_thread legacy_image render_process music_pcm_fanout music_pcm_downmix; do
    "${CXX:-g++}" -std="$standard" -pthread \
      "$repo_root/test/native/visualizer_${name}_test.cc" -ldl \
      -o "$test_output/${name}_$standard"
    "$test_output/${name}_$standard"
  done
done
