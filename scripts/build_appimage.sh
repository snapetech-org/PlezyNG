#!/usr/bin/env bash
# Build the fork's x64 AppImage and its matching, repository-specific update feed.
set -euo pipefail
if [[ $# != 4 ]]; then
  echo "Usage: $0 BUNDLE_DIR OUTPUT_DIR VERSION OWNER/REPOSITORY" >&2
  exit 2
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle="$(realpath "$1")"
output="$(realpath "$2")"
version="$3"
repository="$4"
[[ -d "$bundle" && -d "$output" && -n "$version" ]]
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
command -v zsyncmake >/dev/null || { echo 'zsyncmake is required for AppImage updates' >&2; exit 1; }
scratch="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pleazyng-appimage.XXXXXXXX")"
cleanup() {
  result=$?
  if [[ $result == 0 ]]; then
    rm -rf -- "$scratch"
  else
    echo "Retained AppImage build diagnostics: $scratch" >&2
  fi
}
trap cleanup EXIT
app_dir="$scratch/pleazyng.AppDir"
tool="$scratch/appimagetool"
runtime="$scratch/runtime-x86_64"
python3 "$root/scripts/prepare_native_downloads.py" --appimage-runtime "$runtime"
python3 "$root/scripts/prepare_native_downloads.py" --github-url \
  https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage \
  --expected-sha ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0 --output "$tool"
chmod +x "$tool"
install -d "$app_dir/opt/pleazyng" "$app_dir/usr/share/applications" "$app_dir/usr/share/icons/hicolor/512x512/apps"
cp -a "$bundle"/. "$app_dir/opt/pleazyng/"
install -Dm755 "$root/linux/packaging/appimage/AppRun" "$app_dir/AppRun"
install -Dm644 "$root/linux/packaging/appimage/pleazyng.desktop" "$app_dir/pleazyng.desktop"
install -Dm644 "$root/linux/packaging/appimage/pleazyng.desktop" "$app_dir/usr/share/applications/pleazyng.desktop"
install -Dm644 "$root/assets/pleazyng.png" "$app_dir/pleazyng.png"
install -Dm644 "$root/assets/pleazyng.png" "$app_dir/usr/share/icons/hicolor/512x512/apps/pleazyng.png"
image="$output/pleazyng-linux-x86_64.AppImage"
# appimagetool follows OWD when locating zsyncmake's output, including when
# another AppImage supplied an inherited OWD. Pin it to the artifact directory.
(cd "$output" && OWD="$output" APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 VERSION="$version" \
  "$tool" --no-appstream --runtime-file "$runtime" \
  --updateinformation "gh-releases-zsync|${repository%/*}|${repository#*/}|latest|${image##*/}.zsync" \
  "$app_dir" "$image")
python3 "$root/scripts/verify_appimage_update.py" --image "$image" --repository "$repository"
