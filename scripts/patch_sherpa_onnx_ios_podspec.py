#!/usr/bin/env python3
"""Add a build source to the source-less Sherpa ONNX iOS CocoaPod.

sherpa_onnx_ios 2.0.1 declares a vendored native XCFramework but no CocoaPods
source files. The iOS CI run links SherpaOnnxC without staging it. Include the
package's existing no-op Swift source so CocoaPods builds the native target.

This edits only the resolved package cache copy. The exact package version,
Podspec shape, and anchor source are checked before any change is made.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse


ROOT = Path(__file__).resolve().parent.parent
EXPECTED_VERSION = "2.0.1"
PATCHES = (
    {
        "name": "sherpa_onnx_ios",
        "podspec": "ios/sherpa_onnx_ios.podspec",
        "anchor": "ios/sherpa_onnx_ios/Sources/sherpa_onnx_ios/SherpaOnnxIosPlugin.swift",
        "vendor_line": "  s.vendored_frameworks = 'sherpa_onnx_ios/SherpaOnnxC.xcframework'",
        "source_line": "  s.source_files = 'sherpa_onnx_ios/Sources/sherpa_onnx_ios/SherpaOnnxIosPlugin.swift'",
    },
)


def fail(message: str) -> int:
    print(f"error: {message}", file=sys.stderr)
    return 1


def main() -> int:
    package_config = ROOT / ".dart_tool/package_config.json"
    if not package_config.is_file():
        # Static CodeQL checkout may install pods without resolving Flutter
        # plugins. Normal Flutter builds run pub get first and take the path
        # below; leave the pre-existing static-analysis path unchanged.
        print("skip: Flutter package configuration is not present")
        return 0

    config = json.loads(package_config.read_text(encoding="utf-8"))
    packages = {item.get("name"): item for item in config.get("packages", [])}
    for patch in PATCHES:
        entry = packages.get(patch["name"])
        if entry is None:
            print(f"skip: {patch['name']} is not in the resolved Flutter package graph")
            continue

        uri = urlparse(entry.get("rootUri", ""))
        if uri.scheme == "file":
            plugin = Path(unquote(uri.path))
        elif not uri.scheme:
            plugin = (package_config.parent / unquote(uri.path)).resolve()
        else:
            return fail(f"unsupported {patch['name']} package URI scheme: {uri.scheme}")

        pubspec = plugin / "pubspec.yaml"
        podspec = plugin / patch["podspec"]
        anchor = plugin / patch["anchor"]
        if not plugin.is_dir():
            return fail(f"resolved {patch['name']} plugin is missing: {plugin}")
        if not pubspec.is_file() or not podspec.is_file():
            return fail(f"resolved {patch['name']} package is missing its pubspec or Podspec")
        if not anchor.is_file():
            return fail(f"expected the package's no-op Swift source at {anchor}")

        pubspec_text = pubspec.read_text(encoding="utf-8")
        version_match = re.search(r"(?m)^version:\s*['\"]?([^'\"\s]+)", pubspec_text)
        if not version_match or version_match.group(1) != EXPECTED_VERSION:
            actual = version_match.group(1) if version_match else "missing"
            return fail(f"expected {patch['name']} {EXPECTED_VERSION}, found {actual}; review this Podspec patch")

        if anchor.read_text(encoding="utf-8").strip() != "import Foundation":
            return fail(f"the {patch['name']} Swift anchor changed; review before adding it to CocoaPods")

        podspec_text = podspec.read_text(encoding="utf-8")
        if patch["source_line"] in podspec_text:
            print(f"ready: {patch['name']} {EXPECTED_VERSION} CocoaPods source anchor is present")
            continue
        if re.search(r"(?m)^\s*s\.source_files\s*=", podspec_text):
            return fail(f"{patch['name']} Podspec already declares different source files")
        if podspec_text.count(patch["vendor_line"]) != 1:
            return fail(f"{patch['name']} Podspec no longer matches its expected vendored native binary declaration")

        podspec.write_text(
            podspec_text.replace(patch["vendor_line"], f"{patch['vendor_line']}\n{patch['source_line']}", 1),
            encoding="utf-8",
        )
        print(f"patched: {patch['name']} {EXPECTED_VERSION} CocoaPods source anchor")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
