#!/usr/bin/env python3
"""Require a deliverable for every owner-mandated release platform."""
from __future__ import annotations

import argparse
import fnmatch
import json
from pathlib import Path
import sys

# Each tuple is an independently required asset. Patterns permit the webOS
# packager's versioned application identifier without accepting another format.
REQUIRED = {
    "Android": ("pleazyng-android-arm64-v8a.tar.gz", "pleazyng-android-armeabi-v7a.tar.gz", "pleazyng-android-x86_64.tar.gz"),
    "Fire TV / Stick": ("pleazyng-amazon-firetv.apk", "pleazyng-amazon-firetv-provenance.json"),
    "Linux x64": ("pleazyng-linux-x64.tar.gz",),
    "Linux ARM64": ("pleazyng-linux-arm64.tar.gz",),
    "Windows x64": ("pleazyng-windows-x64-portable.7z",),
    "Windows ARM64": ("pleazyng-windows-arm64-portable.zip",),
    "macOS universal": ("pleazyng-macos.dmg",),
    "iOS": ("pleazyng-ios-unsigned.ipa",),
    "tvOS": ("pleazyng-tvos-unsigned.ipa",),
    "Tizen": ("pleazyng-tizen-arm-tester-handoff.zip",),
    "webOS": ("*.ipk", "webos-app-provenance.json", "webos-engine-provenance.json", "webos-compatibility.json", "webos-SHA256SUMS.txt", "pleazyng-lg-webos-submission.zip"),
}


def missing_assets(names: set[str]) -> list[str]:
    return [f"{platform}: {pattern}" for platform, patterns in REQUIRED.items()
            for pattern in patterns if not any(fnmatch.fnmatchcase(name, pattern) for name in names)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--directory", type=Path)
    source.add_argument("--release-json", type=Path)
    args = parser.parse_args()
    if args.directory is not None:
        names = {file.name for file in args.directory.rglob('*')
                 if file.is_file() and not file.is_symlink() and file.stat().st_size > 0}
    else:
        release = json.loads(args.release_json.read_text())
        names = {asset['name'] for asset in release.get('assets', [])
                 if isinstance(asset, dict) and isinstance(asset.get('name'), str) and asset.get('size', 0) > 0}
    missing = missing_assets(names)
    if missing:
        print("Release platform coverage is incomplete:\n" + '\n'.join(missing), file=sys.stderr)
        return 1
    print("Every required release platform has a nonempty deliverable")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
