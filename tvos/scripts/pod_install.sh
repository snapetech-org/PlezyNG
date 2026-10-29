#!/usr/bin/env bash
# Runs `pod install` for the tvOS target with UTF-8 locale forced — CocoaPods
# 1.16 on Ruby 4.0 crashes with Encoding::CompatibilityError when LANG/LC_ALL
# are unset or non-UTF-8.

set -euo pipefail

TVOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TVOS_DIR"

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

python3 - "$TVOS_DIR" <<'PY'
import json
from pathlib import Path
import sys

tvos_dir = Path(sys.argv[1]).resolve()
root = tvos_dir.parent
metadata = root / ".flutter-plugins-dependencies"
if not metadata.is_file():
    raise SystemExit(f"Missing Flutter plugin metadata: {metadata}")

plugins = json.loads(metadata.read_text(encoding="utf-8"))
required = {"os_media_controls", "universal_gamepad", "wakelock_plus"}
entries = {
    item["name"]: Path(item["path"])
    for item in plugins.get("plugins", {}).get("ios", [])
    if item.get("name") in required
}
missing = required - entries.keys()
if missing:
    raise SystemExit(f"Missing tvOS CocoaPods plugins: {', '.join(sorted(missing))}")

links = root / "ios" / ".symlinks" / "plugins"
links.mkdir(parents=True, exist_ok=True)
# Match the stable relative source paths already recorded in tvos/Podfile.lock;
# using Pub-cache paths here would bake runner-specific locations into the lock.
for name, package in entries.items():
    if not package.is_absolute():
        package = root / package
    package = package.resolve(strict=True)
    pod_dir = package / "ios"
    if not pod_dir.is_dir():
        raise SystemExit(f"Missing iOS podspec directory for {name}: {pod_dir}")

    link = links / name
    if link.is_symlink():
        if link.resolve() == package:
            continue
        link.unlink()
    elif link.exists():
        raise SystemExit(f"Refusing to replace non-symlink Flutter plugin path: {link}")
    link.symlink_to(package, target_is_directory=True)
PY

ruby "$TVOS_DIR/scripts/wire_plugins.rb"
exec pod install --deployment "$@"
