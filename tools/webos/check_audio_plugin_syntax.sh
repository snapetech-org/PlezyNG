#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${WEBOS_NDK_ROOT:?Set the pinned webOS NDK root}"
: "${WEBOS_ENGINE_COMMON_ARCHIVE:?Set the pinned webOS common-runtime archive}"
: "${WEBOS_ENGINE_ARM_ARCHIVE:?Set the pinned webOS ARM-runtime archive}"
WEBOS_PYTHON_BIN="${WEBOS_PYTHON_BIN:-python3}"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/pleazyng-webos-native-syntax.XXXXXXXX")"
trap 'rm -rf -- "$scratch_dir"' EXIT
printf 'WebOS native preflight scratch: %s\n' "$scratch_dir"

"$WEBOS_PYTHON_BIN" - "$ROOT" "$WEBOS_ENGINE_COMMON_ARCHIVE" "$scratch_dir" "$WEBOS_ENGINE_ARM_ARCHIVE" <<'PY'
import hashlib
import json
from pathlib import Path, PurePosixPath
import stat
import sys
import zipfile

root, archive, scratch, arm_archive = map(Path, sys.argv[1:])
pins = json.loads((root / 'tools/webos/compatibility.json').read_text())['lgArtifacts']
expected = pins['commonArchiveSha256']
if archive.is_symlink() or not archive.is_file() or hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
    raise SystemExit('WebOS syntax validation requires the checksum-pinned common-runtime archive.')
with zipfile.ZipFile(archive) as source:
    entries = source.infolist()
    if len({row.filename for row in entries}) != len(entries):
        raise SystemExit('Duplicate common-runtime entries.')
    for row in entries:
        if not row.filename.startswith(('include/', 'runner_base/public/')) or row.is_dir():
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
if arm_archive.is_symlink() or not arm_archive.is_file() or hashlib.sha256(arm_archive.read_bytes()).hexdigest() not in {pins['baseEngineArchiveSha256'], pins['engineArchiveSha256']}:
    raise SystemExit('WebOS link validation requires the pinned ARM-runtime archive.')
with zipfile.ZipFile(arm_archive) as source:
    matches = [row for row in source.infolist() if row.filename == 'libflutter_common.so']
    if len(matches) != 1 or stat.S_ISLNK(matches[0].external_attr >> 16):
        raise SystemExit('Pinned ARM-runtime archive has no unique regular common library.')
    content = source.read(matches[0])
    if hashlib.sha256(content).hexdigest() != pins['runtimeLibraries']['libflutter_common.so']:
        raise SystemExit('Pinned Flutter common runtime hash mismatch.')
    (scratch / 'libflutter_common.so').write_bytes(content)
if (root / 'webos/CMakeLists.txt').read_text().count('target_link_libraries(${BINARY_NAME} PRIVATE flutter)') != 1:
    raise SystemExit('The webOS runner must link the SDK Flutter/common interface directly.')
PY

"$WEBOS_PYTHON_BIN" "$ROOT/tools/webos/ndk_environment.py" \
  --root "$WEBOS_NDK_ROOT" --verify
"$WEBOS_PYTHON_BIN" "$ROOT/tools/webos/ndk_environment.py" \
  --root "$WEBOS_NDK_ROOT" --emit-shell > "$scratch_dir/ndk.env"
source "$ROOT/tools/webos/source_ndk_environment.sh"
pleazyng_source_ndk_environment "$scratch_dir/ndk.env"

# Flutter-webOS's release CMake route uses the NDK Clang frontend, even though
# the SDK environment's CXX names GCC. GCC-only preflight misses Clang's strict
# diagnostics (including anonymous C++ typedefs with default initializers).
clang="$OECORE_NATIVE_SYSROOT/usr/bin/clang++"
if [[ ! -x "$clang" ]]; then
  echo 'The pinned webOS release Clang compiler is missing.' >&2
  exit 1
fi
compiler=("$clang" --target=arm-webosmllib32-linux-gnueabi "--sysroot=$SDKTARGETSYSROOT"
          -mfpu=neon -mfloat-abi=softfp)
# The release Clang emits these atomic ABI calls for the worker. LG's SDK
# provides shared libatomic (also linked by its generated runner), not a
# static archive. Check this dependency before compiling the whole app.
cat > "$scratch_dir/atomic_link_probe.cc" <<'CPP'
int atomic_add(int* p) { return __atomic_fetch_add(p, 1, __ATOMIC_SEQ_CST); }
bool atomic_load(bool* p) { return __atomic_load_n(p, __ATOMIC_SEQ_CST); }
void atomic_store(bool* p) { __atomic_store_n(p, true, __ATOMIC_SEQ_CST); }
bool atomic_swap(bool* p, bool* expected) {
  return __atomic_compare_exchange_n(p, expected, true, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}
int main() {
  int count = 7;
  bool value = false, expected = false;
  if (atomic_add(&count) != 7 || count != 8) return 1;
  atomic_store(&value);
  if (!atomic_load(&value)) return 2;
  if (atomic_swap(&value, &expected) || !expected) return 3;
  value = false;
  expected = false;
  return atomic_swap(&value, &expected) && value ? 0 : 4;
}
CPP
"${compiler[@]}" -std=c++17 -Wl,-z,defs "$scratch_dir/atomic_link_probe.cc" \
  -latomic -o "$scratch_dir/atomic_link_probe"
echo 'Worker atomic operations link against the pinned ARM SDK shared runtime.'
read -r -a flags <<< "$(pkg-config --cflags PmLogLib pbnjson_cpp glib-2.0 ndlmedia alsa ogg opus libcurl)"
plugin="$ROOT/packages/webos_plugins/audioplayers_soloud/webos"
includes=(-I "$scratch_dir/include" -iquote "$plugin" -I "$plugin/include"
          -I "$plugin/../src" -I "$plugin/../src/soloud/include" -I "$plugin/../src/soloud/src")
failures=0
video_plugin="$ROOT/packages/webos_plugins/video_player_drm/webos"
for unit in "$plugin"/*.cc "$video_plugin"/*.cc "$ROOT/webos/runner/main.cc"; do
  printf 'Checking webOS ARM source: %s\n' "${unit##*/}"
  if ! "${compiler[@]}" -std=c++17 -fsyntax-only -Wall -Werror \
      -Wno-unused-command-line-argument -DFLUTTER_PLUGIN_IMPL \
      "${flags[@]}" "${includes[@]}" -I "$video_plugin/include" \
      -I "$scratch_dir/runner_base/public" -I "$ROOT/webos" "$unit"; then
    failures=$((failures + 1))
  fi
done
if (( failures != 0 )); then
  printf 'WebOS media plugins/runner have %s incompatible native translation units.\n' "$failures" >&2
  exit 1
fi
echo 'All webOS audio/video plugins and the navigation runner match the pinned ARM SDK.'

cat > "$scratch_dir/navigation_codec_probe.cc" <<'CPP'
#include <flutter/standard_message_codec.h>
extern "C" const void* navigation_codec_probe() {
  return &flutter::StandardMessageCodec::GetInstance();
}
CPP
"${compiler[@]}" -std=c++17 -shared -fPIC -Wl,-z,defs \
  -I "$scratch_dir/include" "$scratch_dir/navigation_codec_probe.cc" \
  "$scratch_dir/libflutter_common.so" -o "$scratch_dir/navigation_codec_probe.so"
echo 'The navigation codec links against the checksum-pinned ARM Flutter common runtime.'
