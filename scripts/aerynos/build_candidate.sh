#!/usr/bin/env bash
# Build the ordinary Linux release bundle; channel packaging happens after this.
set -euo pipefail
source_dir=$(realpath "$1")
output_dir=$(realpath -m "$2")
cd "$source_dir"
mkdir -p "$output_dir"
export CMAKE_BUILD_PARALLEL_LEVEL=2 CARGO_BUILD_JOBS=2 FLUTTER_WHISPER_GPU_BACKEND=CPU
export PKG_CONFIG_PATH="$source_dir/libmpv-prefix/lib/pkgconfig:$source_dir/libmpv-prefix/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
flutter pub get --enforce-lockfile --no-example
python3 scripts/fetch_linux_libmpv.py --dest libmpv-prefix
python3 scripts/prepare_native_downloads.py --sqlite-platform linux --cmake-deps --arch x64
python3 scripts/visualizer/build_runtime.py --platform linux --architectures x64 --output build/visualizer-native
source_sha=$(git rev-parse HEAD)
flutter build linux --release --dart-define=SUPPORTER_MODE=unlocked \
  --dart-define=ENABLE_UPDATE_CHECK=true --dart-define="GIT_COMMIT=$source_sha" \
  --split-debug-info=debug-info/linux-x64
bundle=build/linux/x64/release/bundle
python3 linux/packaging/install-sherpa-onnx-runtime.py "$bundle" --arch x64
mpv_dir=$(dirname "$(find libmpv-prefix -name libmpv.so -print -quit)")
cp -a "$mpv_dir"/libmpv.so* libmpv-prefix/lib/libshaderc_shared.so* libmpv-prefix/lib/libvulkan.so* "$bundle/lib/"
bash linux/packaging/bundle-libs.sh "$bundle"
bash linux/packaging/prepare-bundle-launcher.sh "$bundle"
cp assets/pleazyng.png "$bundle/pleazyng.png"
python3 linux/packaging/check-bundle-host-deps.py "$bundle"
tar -czf "$output_dir/pleazyng-linux-x64.tar.gz" -C "$bundle" .
git archive --format=tar.gz --prefix=pleazyng-source/ --output="$output_dir/pleazyng-source.tar.gz" HEAD
python3 - "$output_dir" <<'PY'
import hashlib,json,pathlib,re,subprocess,sys
out=pathlib.Path(sys.argv[1]); version=re.search(r'^version:\s*(\S+)',pathlib.Path('pubspec.yaml').read_text(),re.M).group(1)
hashes={p.name:hashlib.file_digest(p.open('rb'),'sha256').hexdigest() for p in sorted(out.glob('*.tar.gz'))}
(out/'SHA256SUMS.txt').write_text(''.join(f'{v}  {k}\n' for k,v in hashes.items()))
(out/'build.json').write_text(json.dumps({'source_sha':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'version':version,'assets':hashes},indent=2)+'\n')
PY
