#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${WEBOS_NDK_ROOT:?Set the pinned webOS NDK root}"
: "${WEBOS_ENGINE_COMMON_ARCHIVE:?Set the pinned webOS common-runtime archive}"
WEBOS_PYTHON_BIN="${WEBOS_PYTHON_BIN:-python3}"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/pleazyng-webos-native-syntax.XXXXXXXX")"
trap 'rm -rf -- "$scratch_dir"' EXIT
printf 'WebOS native preflight scratch: %s\n' "$scratch_dir"

"$WEBOS_PYTHON_BIN" - "$ROOT" "$WEBOS_ENGINE_COMMON_ARCHIVE" "$scratch_dir" <<'PY'
import hashlib
import json
from pathlib import Path, PurePosixPath
import stat
import sys
import zipfile

root, archive, scratch = map(Path, sys.argv[1:])
expected = json.loads((root / 'tools/webos/compatibility.json').read_text())['lgArtifacts']['commonArchiveSha256']
if archive.is_symlink() or not archive.is_file() or hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
    raise SystemExit('WebOS syntax validation requires the checksum-pinned common-runtime archive.')
with zipfile.ZipFile(archive) as source:
    entries = source.infolist()
    if len({row.filename for row in entries}) != len(entries):
        raise SystemExit('Duplicate common-runtime entries.')
    for row in entries:
        if not row.filename.startswith('include/') or row.is_dir():
            continue
        name = PurePosixPath(row.filename)
        if (name.is_absolute() or '..' in name.parts or '\\' in row.filename
                or stat.S_ISLNK(row.external_attr >> 16) or row.file_size > 2 * 1024**2):
            raise SystemExit('Unsafe common-runtime header entry.')
        output = scratch / name
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(source.read(row))
if not (scratch / 'include/flutter/texture_registrar.h').is_file():
    raise SystemExit('Pinned common-runtime archive has no C++ texture registrar headers.')
PY

"$WEBOS_PYTHON_BIN" "$ROOT/tools/webos/ndk_environment.py" \
  --root "$WEBOS_NDK_ROOT" --verify
"$WEBOS_PYTHON_BIN" "$ROOT/tools/webos/ndk_environment.py" \
  --root "$WEBOS_NDK_ROOT" --emit-shell > "$scratch_dir/ndk.env"
source "$ROOT/tools/webos/source_ndk_environment.sh"
pleazyng_source_ndk_environment "$scratch_dir/ndk.env"

read -r -a compiler <<< "$CXX"
read -r -a flags <<< "$(pkg-config --cflags PmLogLib pbnjson_cpp glib-2.0 ndlmedia alsa ogg opus libcurl)"
plugin="$ROOT/packages/webos_plugins/audioplayers_soloud/webos"
includes=(-I "$scratch_dir/include" -iquote "$plugin" -I "$plugin/include"
          -I "$plugin/../src" -I "$plugin/../src/soloud/include" -I "$plugin/../src/soloud/src")
failures=0
for unit in "$plugin"/*.cc; do
  printf 'Checking webOS ARM source: %s\n' "${unit##*/}"
  if ! "${compiler[@]}" -std=c++17 -fsyntax-only -DFLUTTER_PLUGIN_IMPL \
      "${flags[@]}" "${includes[@]}" "$unit"; then
    failures=$((failures + 1))
  fi
done
if (( failures != 0 )); then
  printf 'WebOS audio plugin has %s incompatible native translation units.\n' "$failures" >&2
  exit 1
fi
echo 'All webOS audio plugin translation units match the pinned ARM SDK.'
