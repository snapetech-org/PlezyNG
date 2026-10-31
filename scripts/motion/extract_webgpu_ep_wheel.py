#!/usr/bin/env python3
"""Extract the pinned ONNX Runtime WebGPU plugin and notices for native packaging."""

from __future__ import annotations

import argparse
import hashlib
from email.parser import Parser
from pathlib import Path
import zipfile


EXPECTED_DISTRIBUTION = "onnxruntime-ep-webgpu"
EXPECTED_VERSION = "0.5.0"
PACKAGE_PREFIX = "onnxruntime_ep_webgpu/"
PLUGIN_NAME = "libonnxruntime_providers_webgpu.so"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def extract(wheel: Path, output: Path, expected_sha256: str) -> list[str]:
    actual_sha256 = sha256_file(wheel)
    if actual_sha256.lower() != expected_sha256.lower():
        raise ValueError(f"Wheel SHA-256 mismatch: expected {expected_sha256}, got {actual_sha256}")

    with zipfile.ZipFile(wheel) as archive:
        names = set(archive.namelist())
        plugins = [name for name in names if name == PACKAGE_PREFIX + PLUGIN_NAME]
        metadata_members = [name for name in names if name.endswith(".dist-info/METADATA")]
        licenses = [name for name in names if name.endswith(".dist-info/licenses/LICENSE")]
        notices = [name for name in names if name.endswith(".dist-info/licenses/ThirdPartyNotices.txt")]
        if any(len(items) != 1 for items in (plugins, metadata_members, licenses, notices)):
            raise ValueError("WebGPU wheel is missing its unique provider, metadata, license, or third-party notices")

        metadata = Parser().parsestr(archive.read(metadata_members[0]).decode("utf-8"))
        if (
            (metadata.get("Name") or "").lower() != EXPECTED_DISTRIBUTION
            or metadata.get("Version") != EXPECTED_VERSION
            or metadata.get("License-Expression") != "MIT"
        ):
            raise ValueError("WebGPU wheel metadata does not match the pinned package, version, and MIT license")

        output.mkdir(parents=True, exist_ok=True)
        files = (
            (plugins[0], PLUGIN_NAME),
            (licenses[0], "WebGPU-License.txt"),
            (notices[0], "WebGPU-ThirdPartyNotices.txt"),
        )
        written = []
        for member, output_name in files:
            (output / output_name).write_bytes(archive.read(member))
            written.append(output_name)
        return written


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wheel", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("sha256")
    args = parser.parse_args()
    files = extract(args.wheel, args.output_dir, args.sha256)
    print(f"Extracted {len(files)} WebGPU EP runtime files to {args.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
