#!/usr/bin/env bash
# Format maintained Dart source without changing canonical generator outputs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
options=()
case "${1:-}" in
  '') ;;
  --check) options=(--output=none --set-exit-if-changed) ;;
  *) echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac
paths=(lib)
[[ ! -d test ]] || paths+=(test)
files=()
while IFS= read -r -d '' source; do files+=("$source"); done < <(
  find "${paths[@]}" -type f -name '*.dart' ! -name '*.g.dart' ! -name '*.freezed.dart' -print0
)
[[ ${#files[@]} -eq 0 ]] || dart format "${options[@]}" "${files[@]}"
