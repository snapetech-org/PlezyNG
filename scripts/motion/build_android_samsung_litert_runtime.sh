#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${PLEZY_LITERT_SOURCE_ROOT:-}" ]]; then
  echo "Set PLEZY_LITERT_SOURCE_ROOT to a LiteRT v2.3.0 checkout." >&2
  exit 2
fi
if [[ -z "${EXYNOS_AI_LITECORE_ROOT:-}" ]]; then
  echo "Set EXYNOS_AI_LITECORE_ROOT to the LiteCore SDK obtained through Samsung's authorized download flow." >&2
  exit 2
fi
if [[ -z "${PLEZY_LITERT_SAMSUNG_RUNTIME_OUTPUT:-}" ]]; then
  echo "Set PLEZY_LITERT_SAMSUNG_RUNTIME_OUTPUT to a new output directory." >&2
  exit 2
fi
for tool in bazel cp cut find git grep mkdir mktemp mv readelf realpath sha256sum sort xargs; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required tool is missing from PATH: $tool" >&2
    exit 2
  fi
done

source_root="$(realpath "$PLEZY_LITERT_SOURCE_ROOT")"
litecore_root="$(realpath "$EXYNOS_AI_LITECORE_ROOT")"
script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compatibility_patch="$script_root/patches/litert-v2.3.0-samsung-flatbuffers-link.patch"
if [[ ! -f "$compatibility_patch" ]]; then
  echo "LiteRT Samsung compatibility patch is missing: $compatibility_patch" >&2
  exit 2
fi
output_parent="$(mkdir -p "$(dirname "$PLEZY_LITERT_SAMSUNG_RUNTIME_OUTPUT")" && cd "$(dirname "$PLEZY_LITERT_SAMSUNG_RUNTIME_OUTPUT")" && pwd)"
output_dir="$output_parent/$(basename "$PLEZY_LITERT_SAMSUNG_RUNTIME_OUTPUT")"

if [[ "$(git -C "$source_root" describe --tags --exact-match 2>/dev/null || true)" != "v2.3.0" ]]; then
  echo "PLEZY_LITERT_SOURCE_ROOT must be checked out at the v2.3.0 tag." >&2
  exit 2
fi
source_commit="$(git -C "$source_root" rev-parse HEAD)"
if [[ "$source_commit" != "4352e261d3f1b3cda00345db5dbd75859d3bf0d3" ]]; then
  echo "LiteRT v2.3.0 tag does not match the source revision this build was qualified against." >&2
  exit 2
fi
if [[ -n "$(git -C "$source_root" status --porcelain --untracked-files=all)" ]]; then
  echo "PLEZY_LITERT_SOURCE_ROOT must be a clean checkout; the build uses an isolated worktree." >&2
  exit 2
fi
if [[ -e "$output_dir" ]]; then
  echo "Output already exists; choose a new path so stale LiteCore files cannot be mixed: $output_dir" >&2
  exit 2
fi
for required in \
  "$litecore_root/include/graph_wrapper_api.h" \
  "$litecore_root/include/graphgen_c.h" \
  "$litecore_root/lib/arm64-v8a/libgraph_wrapper.so" \
  "$litecore_root/lib/arm64-v8a/libgraphgen_api.so" \
  "$litecore_root/lib/x86_64-linux/libgraph_wrapper.so" \
  "$litecore_root/lib/x86_64-linux/libgraphgen_api.so"; do
  if [[ ! -f "$required" ]]; then
    echo "LiteCore SDK is missing $required" >&2
    exit 2
  fi
done

source_worktree_parent="$output_parent/.plezy-litert-samsung-source"
if [[ -e "$source_worktree_parent" ]]; then
  echo "Temporary LiteRT build workspace already exists; inspect it before retrying: $source_worktree_parent" >&2
  exit 2
fi
build_source_root="$source_worktree_parent/source"
staging_dir=""
cleanup_staging() {
  if [[ -n "${staging_dir:-}" && -d "$staging_dir" ]]; then
    rm -rf -- "$staging_dir"
  fi
  if [[ -n "${build_source_root:-}" && -d "$build_source_root" ]]; then
    git -C "$source_root" worktree remove --force "$build_source_root" >/dev/null 2>&1 ||
      rm -rf -- "$build_source_root"
  fi
  if [[ -n "${source_worktree_parent:-}" && -d "$source_worktree_parent" ]]; then
    rmdir -- "$source_worktree_parent" 2>/dev/null || true
  fi
}
trap cleanup_staging EXIT

mkdir "$source_worktree_parent"
git -C "$source_root" worktree add --detach "$build_source_root" "$source_commit"
git -C "$build_source_root" apply "$compatibility_patch"

staging_dir="$(mktemp -d "$output_parent/.plezy-litert-samsung.XXXXXX")"
(
  cd "$build_source_root"
  EXYNOS_AI_LITECORE_ROOT="$litecore_root" \
    bazel build --config=android_arm64 \
      //litert/vendors/samsung/compiler:compiler_plugin_so \
      //litert/vendors/samsung/dispatch:dispatch_api_so
)

bazel_bin="$(cd "$build_source_root" && realpath "$(bazel info --config=android_arm64 bazel-bin)")"
find_android_library() {
  local search_root="$1"
  local library_name="$2"
  local candidate
  while IFS= read -r -d '' candidate; do
    if readelf -h "$candidate" 2>/dev/null | grep -q 'Machine:.*AArch64'; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find -L "$search_root" -type f -name "$library_name" -print0)
  return 1
}

compiler_plugin="$(find_android_library \
  "$bazel_bin/litert/vendors/samsung/compiler" \
  "libLiteRtCompilerPlugin_Samsung.so")" || {
  echo "Could not find the Android arm64 Samsung compiler plugin in Bazel outputs." >&2
  exit 1
}
dispatch_plugin="$(find_android_library \
  "$bazel_bin/litert/vendors/samsung/dispatch" \
  "libLiteRtDispatch_Samsung.so")" || {
  echo "Could not find the Android arm64 Samsung dispatch library in Bazel outputs." >&2
  exit 1
}

mkdir -p "$staging_dir/arm64-v8a" "$staging_dir/litecore/lib/arm64-v8a"
cp "$compiler_plugin" "$staging_dir/arm64-v8a/libLiteRtCompilerPlugin_Samsung.so"
cp "$dispatch_plugin" "$staging_dir/arm64-v8a/libLiteRtDispatch_Samsung.so"
shopt -s nullglob
litecore_android_libraries=("$litecore_root"/lib/arm64-v8a/*.so)
if (( ${#litecore_android_libraries[@]} < 2 )); then
  echo "LiteCore SDK contains fewer than two Android shared libraries." >&2
  exit 2
fi
cp "${litecore_android_libraries[@]}" "$staging_dir/litecore/lib/arm64-v8a/"
[[ -f "$staging_dir/litecore/lib/arm64-v8a/libgraph_wrapper.so" ]]
[[ -f "$staging_dir/litecore/lib/arm64-v8a/libgraphgen_api.so" ]]

{
  printf 'LiteRT source tag: v2.3.0\n'
  printf 'LiteRT source commit: %s\n' "$source_commit"
  printf 'Plezy compatibility patch: %s\n' "$(basename "$compatibility_patch")"
  printf 'Plezy compatibility patch SHA-256: %s\n' "$(sha256sum "$compatibility_patch" | cut -d ' ' -f 1)"
  printf 'LiteCore host and Android libraries are copied from the supplied SDK root.\n'
} > "$staging_dir/BUILD_INFO.txt"
(cd "$staging_dir" && find . -type f -name '*.so' -print0 | sort -z | xargs -0 sha256sum) \
  > "$staging_dir/SHA256SUMS"

mv "$staging_dir" "$output_dir"
staging_dir=""
trap - EXIT
echo "Samsung LiteRT runtime staged at $output_dir"
