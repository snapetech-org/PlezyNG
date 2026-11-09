#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source="$repo_root/native/games/romm/apple/Frameworks/macos/helpers/plezy_retro_worker"
[[ -f "$source" && ! -L "$source" ]] || { echo 'The packaged emulator worker is missing.' >&2; exit 1; }
destination="${TARGET_BUILD_DIR:?}/${EXECUTABLE_FOLDER_PATH:?}/plezy_retro_worker"
mkdir -p "$(dirname "$destination")"
install -m 755 "$source" "$destination"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == YES ]]; then
  identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  stamp=(--timestamp)
  if [[ "$identity" == '-' ]]; then stamp=(--timestamp=none); fi
  # The worker needs no JIT, unsigned executable memory, networking, or app
  # sandbox exceptions. Sign it independently before the enclosing app bundle.
  codesign --force --sign "$identity" --options runtime "${stamp[@]}" "$destination"
fi
