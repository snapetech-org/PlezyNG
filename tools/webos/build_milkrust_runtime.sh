#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${RUNNER_TEMP:?MilkRust webOS builds require the private JIT runner}"
: "${GITHUB_RUN_ID:?The private JIT run ID is required}"
: "${GITHUB_REPOSITORY:?The GitHub repository is required for provenance}"
: "${WEBOS_NDK_ROOT:?Set this to the pinned LG webOS 26 NDK root}"
: "${WEBOS_PYTHON_BIN:=python3}"

if [[ "$GITHUB_REPOSITORY" != "snapetech-org/PlezyNG" || "${RUNNER_ENVIRONMENT:-}" != "self-hosted" ]]; then
  echo "MilkRust webOS provenance must be produced by snapetech-org/PlezyNG." >&2
  exit 1
fi
if [[ ! "$GITHUB_RUN_ID" =~ ^[1-9][0-9]*$ ]]; then
  echo "GITHUB_RUN_ID must contain only decimal digits." >&2
  exit 1
fi
if (( $# != 1 )); then
  echo "Usage: $0 /path/under/RUNNER_TEMP/plezyng-webos-RUN_ID/milkrust-native" >&2
  exit 2
fi

BUNDLE_DIR="$1"
TASK_ROOT="$RUNNER_TEMP/plezyng-webos-$GITHUB_RUN_ID"
if [[ -L "$RUNNER_TEMP" || -L "$TASK_ROOT" || ! -d "$TASK_ROOT" ]]; then
  echo "MilkRust builds require this run's real, existing private task directory." >&2
  exit 1
fi
case "$BUNDLE_DIR" in
  "$TASK_ROOT/milkrust-native") ;;
  *) echo "MilkRust output must be inside this run's private task directory." >&2; exit 1 ;;
esac
if [[ -e "$BUNDLE_DIR" || -L "$BUNDLE_DIR" ]]; then
  echo "Refusing to reuse or overwrite a MilkRust artifact directory: $BUNDLE_DIR" >&2
  exit 1
fi

mapfile -t PIN < <("$WEBOS_PYTHON_BIN" - "$ROOT/native/visualizer/sources.lock.json" "$ROOT/tools/webos/compatibility.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source_lock:
    source = json.load(source_lock)["milkrust"]
with open(sys.argv[2], encoding="utf-8") as compatibility:
    build = json.load(compatibility)["milkrustBuild"]
for value in (
    source["repository"], source["ref"], source["commit"], str(source["abi"]),
    build["toolchain"], build["rustTarget"], build["linker"],
    build["crate"], build["runnerPolicy"],
):
    print(value)
PY
)
if (( ${#PIN[@]} != 9 )); then
  echo "MilkRust build lock is incomplete." >&2
  exit 1
fi
SOURCE_URL="${PIN[0]}"
SOURCE_REF="${PIN[1]}"
SOURCE_REVISION="${PIN[2]}"
ABI="${PIN[3]}"
RUST_TOOLCHAIN="${PIN[4]}"
RUST_TARGET="${PIN[5]}"
LINKER_NAME="${PIN[6]}"
CRATE="${PIN[7]}"
RUNNER_POLICY="${PIN[8]}"
if [[ "$SOURCE_URL" != "https://github.com/snapetech-org/MilkRust.git" ||
      ! "$SOURCE_REF" =~ ^refs/pull/[1-9][0-9]*/head$ ||
      ! "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ || "$ABI" != "2" ||
      "$RUNNER_POLICY" != "private-ephemeral-jit" ]]; then
  echo "MilkRust source or runner identity is invalid." >&2
  exit 1
fi

NDK_ROOT="$(cd -- "$WEBOS_NDK_ROOT" && pwd)"
"$WEBOS_PYTHON_BIN" "$ROOT/tools/webos/ndk_environment.py" --root "$NDK_ROOT" --verify >&2
LINKER="$NDK_ROOT/sysroots/x86_64-starfishsdk-linux/usr/bin/arm-webos-linux-gnueabi/$LINKER_NAME"
if [[ -L "$LINKER" || ! -x "$LINKER" ]]; then
  echo "The pinned webOS linker is missing or linked: $LINKER" >&2
  exit 1
fi

# cc-rs now compiles the vendored HLSL parser. Explicit target tools and flags
# prevent an accidental host-C++ object from entering the ARM Rust archive.
CXX="${LINKER%-gcc}-g++"
AR="${LINKER%-gcc}-ar"
TARGET_SYSROOT="$NDK_ROOT/sysroots/ca9v1-webosmllib32-linux-gnueabi"
for tool in "$CXX" "$AR"; do
  if [[ -L "$tool" || ! -x "$tool" ]]; then
    echo "The pinned NDK C++ tool is missing or linked: $tool" >&2
    exit 1
  fi
done
EXPECTED_GCC="$("$WEBOS_PYTHON_BIN" -c 'import json,sys; print(json.load(open(sys.argv[1]))["engineBuild"]["gccVersion"])' "$ROOT/tools/webos/compatibility.json")"
if [[ "$("$CXX" -dumpfullversion)" != "$EXPECTED_GCC" ]]; then
  echo "MilkRust C++ compiler differs from the webOS NDK version." >&2
  exit 1
fi
TARGET_FLAGS="--sysroot=$TARGET_SYSROOT -march=armv7-a -marm -mfpu=neon -mfloat-abi=softfp"
unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS
export CC_armv7_unknown_linux_gnueabi="$LINKER"
export CXX_armv7_unknown_linux_gnueabi="$CXX"
export AR_armv7_unknown_linux_gnueabi="$AR"
export CFLAGS_armv7_unknown_linux_gnueabi="$TARGET_FLAGS"
export CXXFLAGS_armv7_unknown_linux_gnueabi="$TARGET_FLAGS"
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABI_RUSTFLAGS="-C link-arg=--sysroot=$TARGET_SYSROOT -C link-arg=-march=armv7-a -C link-arg=-mfloat-abi=softfp -C link-arg=-mfpu=neon"

TASK_ROOT_REAL="$(cd -- "$TASK_ROOT" && pwd)"
TASK_RUSTUP_HOME="$TASK_ROOT_REAL/rustup-home"
TASK_CARGO_HOME="$TASK_ROOT_REAL/cargo-home"
TASK_SOURCE="$TASK_ROOT_REAL/milkrust-source"
TASK_TARGET="$TASK_ROOT_REAL/milkrust-target"
mkdir -m 700 -- "$TASK_RUSTUP_HOME" "$TASK_CARGO_HOME"
export RUSTUP_HOME="$TASK_RUSTUP_HOME"
export CARGO_HOME="$TASK_CARGO_HOME"

if ! command -v rustup >/dev/null 2>&1; then
  echo "The approved private JIT image must provide rustup." >&2
  exit 1
fi
rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal --target "$RUST_TARGET" >&2
RUSTC_VERSION="$(rustup run "$RUST_TOOLCHAIN" rustc --version)"
CARGO_VERSION="$(rustup run "$RUST_TOOLCHAIN" cargo --version)"
if [[ "$RUSTC_VERSION" != "rustc $RUST_TOOLCHAIN "* || "$CARGO_VERSION" != "cargo $RUST_TOOLCHAIN "* ]]; then
  echo "Rust compiler and Cargo do not match the locked toolchain $RUST_TOOLCHAIN." >&2
  exit 1
fi

git -c protocol.file.allow=never clone --filter=blob:none --no-checkout "$SOURCE_URL" "$TASK_SOURCE" >&2
git -C "$TASK_SOURCE" fetch --filter=blob:none --no-tags origin "$SOURCE_REF" >&2
git -C "$TASK_SOURCE" checkout --detach "$SOURCE_REVISION" >&2
if [[ "$(git -C "$TASK_SOURCE" rev-parse HEAD)" != "$SOURCE_REVISION" || -n "$(git -C "$TASK_SOURCE" status --porcelain)" ]]; then
  echo "MilkRust checkout differs from the immutable source lock or is dirty." >&2
  exit 1
fi

case "$RUST_TARGET" in
  armv7-unknown-linux-gnueabi) CARGO_LINKER_ENV=CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABI_LINKER ;;
  *) echo "Unsupported locked Rust target: $RUST_TARGET" >&2; exit 1 ;;
esac
export CARGO_TARGET_DIR="$TASK_TARGET"
export "$CARGO_LINKER_ENV"="$LINKER"
rustup run "$RUST_TOOLCHAIN" cargo build \
  --locked --release --package "$CRATE" --target "$RUST_TARGET" \
  --manifest-path "$TASK_SOURCE/Cargo.toml" >&2

LIBRARY="$TASK_TARGET/$RUST_TARGET/release/libmilkrust_native.so"
if [[ -L "$LIBRARY" || ! -f "$LIBRARY" ]]; then
  echo "The MilkRust build did not produce a regular shared library." >&2
  exit 1
fi
"$WEBOS_PYTHON_BIN" - "$LIBRARY" <<'PY'
import struct
import sys

with open(sys.argv[1], "rb") as library:
    header = library.read(20)
if len(header) != 20 or header[:4] != b"\x7fELF" or header[4:6] != b"\x01\x01" or struct.unpack_from("<H", header, 18)[0] != 40:
    raise SystemExit("MilkRust runtime is not a little-endian ARM ELF32 library.")
PY

mkdir -m 700 -- "$BUNDLE_DIR"
install -m 0644 -- "$LIBRARY" "$BUNDLE_DIR/libmilkrust_native.so"
cmake -S "$ROOT/native/visualizer/tv-helper" -B "$TASK_ROOT/visualizer-helper-build" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
  "-DCMAKE_CXX_COMPILER=$CXX" "-DCMAKE_SYSROOT=$TARGET_SYSROOT" \
  "-DCMAKE_CXX_FLAGS=-march=armv7-a -marm -mfpu=neon -mfloat-abi=softfp" >&2
cmake --build "$TASK_ROOT/visualizer-helper-build" --config Release >&2
install -m 0755 -- "$TASK_ROOT/visualizer-helper-build/plezy_visualizer_helper" "$BUNDLE_DIR/plezy_visualizer_helper"
HOST_REVISION="$(git -C "$ROOT" rev-parse HEAD)"
if [[ ! "$HOST_REVISION" =~ ^[0-9a-f]{40}$ || -n "$(git -C "$ROOT" status --porcelain -- shared/visualization native/visualizer)" ]]; then
  echo "Visualization host sources must match their committed archive." >&2
  exit 1
fi
git -C "$ROOT" archive --format=tar --prefix="plezy-visualizer-$HOST_REVISION/" "$HOST_REVISION" -- LICENSE shared/visualization native/visualizer |
  gzip --no-name --best > "$BUNDLE_DIR/visualizer-host-source.tar.gz"
git -C "$TASK_SOURCE" archive --format=tar --prefix="milkrust-$SOURCE_REVISION/" "$SOURCE_REVISION" -- Cargo.toml Cargo.lock LICENSE LICENSE-SCOPE.md README.md crates docs tools |
  gzip --no-name --best > "$BUNDLE_DIR/milkrust-source.tar.gz"
install -m 0644 -- "$ROOT/native/visualizer/notices/MilkRust-AGPL-3.0.txt" "$BUNDLE_DIR/MILKRUST-NOTICES.txt"
{
  printf '\n\nVendored HLSLParser (MIT):\n'
  cat "$TASK_SOURCE/crates/milkrust-hlsl/vendor/hlslparser/LICENSE"
  printf '\n\nMilkRust core third-party notices:\n'
  cat "$TASK_SOURCE/crates/milkrust-core/THIRD_PARTY_NOTICES.md"
  printf '\n\nThe PlezyNG visualization helper is AGPL-3.0-only. Corresponding host source and stb_image notices are in visualizer-host-source.tar.gz.\n'
} >> "$BUNDLE_DIR/MILKRUST-NOTICES.txt"

"$WEBOS_PYTHON_BIN" - "$BUNDLE_DIR" "$SOURCE_REVISION" "$ABI" "$RUST_TOOLCHAIN" "$RUST_TARGET" "$RUNNER_POLICY" "$GITHUB_RUN_ID" "$HOST_REVISION" <<'PY'
import hashlib
import json
import struct
import sys
from pathlib import Path

bundle = Path(sys.argv[1])
source_revision, abi, toolchain, target, runner_policy, run_id, host_revision = sys.argv[2:]
header = (bundle / "plezy_visualizer_helper").read_bytes()[:20]
if len(header) != 20 or header[:4] != b"\x7fELF" or header[4:6] != b"\x01\x01" or struct.unpack_from("<H", header, 18)[0] != 40:
    raise SystemExit("Visualization helper is not a little-endian ARM ELF32 executable.")
names = {
    "librarySha256": "libmilkrust_native.so",
    "sourceArchiveSha256": "milkrust-source.tar.gz",
    "noticesSha256": "MILKRUST-NOTICES.txt",
    "helperSha256": "plezy_visualizer_helper",
    "hostSourceArchiveSha256": "visualizer-host-source.tar.gz",
}
manifest = {
    "schemaVersion": 2,
    "renderProtocol": 2,
    "hostSourceRevision": host_revision,
    "abi": int(abi),
    "target": "webos-arm",
    "sourceRevision": source_revision,
    "buildRun": f"https://github.com/snapetech-org/PlezyNG/actions/runs/{run_id}",
    "runnerPolicy": runner_policy,
    "rustToolchain": toolchain,
    "rustTarget": target,
}
for key, filename in names.items():
    manifest[key] = hashlib.sha256((bundle / filename).read_bytes()).hexdigest()
(bundle / "milkrust-native.json").write_text(
    json.dumps(manifest, sort_keys=True, indent=2) + "\n", encoding="utf-8"
)
PY

if [[ "$(find "$BUNDLE_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l)" -ne 6 ]]; then
  echo "MilkRust bundle is missing required artifacts or contains unexpected files." >&2
  exit 1
fi
sha256sum -- "$BUNDLE_DIR/milkrust-native.json" | awk '{ print $1 }'
