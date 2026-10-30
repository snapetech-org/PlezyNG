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

if [[ "$target_platform" == macos ]]; then
  helper_dir="${TARGET_BUILD_DIR:?}/${EXECUTABLE_FOLDER_PATH:?}"
  mkdir -p "$helper_dir"
  helper="$helper_dir/plezy_visualizer_helper"
  helper_arches=()
  for arch in ${ARCHS:?}; do helper_arches+=(-arch "$arch"); done
  xcrun --sdk macosx clang++ -std=c++17 -fobjc-arc -Wno-deprecated-declarations \
    "${helper_arches[@]}" -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    "-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:?}" \
    "$repo_root/shared/apple/MpvPlayer/MilkRustRenderHelper.mm" \
    "$bundle/libmilkrust_native.a" -o "$helper" \
    -framework Foundation -framework CoreFoundation -framework CoreGraphics \
    -framework ImageIO -framework OpenGL -framework Security -liconv -lresolv
  if [[ "${CODE_SIGNING_ALLOWED:-YES}" == YES ]]; then
    helper_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    helper_stamp=(--timestamp)
    if [[ "$helper_identity" == '-' ]]; then helper_stamp=(--timestamp=none); fi
    codesign --force --sign "$helper_identity" --options runtime "${helper_stamp[@]}" "$helper"
  fi
fi
