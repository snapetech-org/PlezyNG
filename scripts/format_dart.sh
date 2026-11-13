#!/usr/bin/env bash
# Format maintained Dart source without changing canonical generator outputs.
# With no paths, format the maintained source tree. Pass files or directories
# to limit formatting to a focused change, for example:
#   scripts/format_dart.sh lib/karaoke/karaoke_audio.dart
#   scripts/format_dart.sh --check lib/karaoke
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
repo_root="$(pwd -P)"
options=()
if [[ "${1:-}" == --check ]]; then
  options=(--output=none --set-exit-if-changed)
  shift
fi
if [[ "${1:-}" == --help ]]; then
  echo "Usage: $0 [--check] [file.dart|directory ...]"
  echo "Without paths, formats maintained Dart files in lib/ and test/."
  exit 0
fi
if [[ $# -eq 0 ]]; then
  paths=(lib)
  [[ ! -d test ]] || paths+=(test)
else
  paths=("$@")
fi
files=()
for path in "${paths[@]}"; do
  if [[ -d "$path" ]]; then
    path="$(cd "$path" && pwd -P)"
    case "$path" in
      "$repo_root"|"$repo_root"/*) ;;
      *) echo "Path must be inside the repository: $path" >&2; exit 2 ;;
    esac
    while IFS= read -r -d '' source; do files+=("$source"); done < <(
      find "$path" -type f -name '*.dart' ! -name '*.g.dart' ! -name '*.freezed.dart' -print0
    )
  elif [[ -f "$path" ]]; then
    if [[ -L "$path" ]]; then
      echo "Refusing to follow a symbolic link: $path" >&2
      exit 2
    fi
    if [[ "$path" != *.dart ]]; then
      echo "Expected a Dart file or directory: $path" >&2
      exit 2
    fi
    if [[ "$path" != *.g.dart && "$path" != *.freezed.dart ]]; then
      source_dir="$(cd "$(dirname "$path")" && pwd -P)"
      case "$source_dir" in
        "$repo_root"|"$repo_root"/*) files+=("$source_dir/$(basename "$path")") ;;
        *) echo "Path must be inside the repository: $path" >&2; exit 2 ;;
      esac
    fi
  else
    echo "Path does not exist or is not a regular file/directory: $path" >&2
    exit 2
  fi
done

if [[ ${#files[@]} -gt 0 ]]; then
  dart format --page-width=120 "${options[@]}" "${files[@]}"
fi
