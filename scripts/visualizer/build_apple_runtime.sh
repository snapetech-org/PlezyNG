#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "${PLATFORM_NAME:?Xcode platform required}" in
  macosx) target_platform=macos ;;
  iphoneos) target_platform=ios ;;
  iphonesimulator) target_platform=ios-simulator ;;
  appletvos) target_platform=tvos ;;
  appletvsimulator) target_platform=tvos-simulator ;;
  *) echo 'Unsupported Apple MilkRust platform' >&2; exit 1 ;;
esac
architectures=""
for arch in ${ARCHS:?Xcode architectures required}; do
  case "$arch" in
    arm64) selected=arm64 ;;
    x86_64) selected=x64 ;;
    *) echo "Unsupported MilkRust architecture: $arch" >&2; exit 1 ;;
  esac
  architectures="${architectures:+$architectures,}$selected"
done
bundle="${DERIVED_FILE_DIR:?}/plezy-milkrust"
python3 "$repo_root/scripts/visualizer/build_runtime.py" \
  --platform "$target_platform" --architectures "$architectures" --output "$bundle"
destination="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/visualizer-notices"
mkdir -p "$destination"
cp "$bundle/assets/visualizer-notices/MILKRUST-NOTICES.txt" "$destination/"
cp "$bundle/assets/visualizer-notices/milkrust-source.tar.gz" "$destination/"
cp "$bundle/milkrust-build.json" "$destination/"
