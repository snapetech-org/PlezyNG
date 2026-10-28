#!/usr/bin/env python3
"""Extract the pinned OpenVINO ONNX Runtime EP wheel for native packaging."""

from __future__ import annotations

import argparse
import hashlib
import zipfile
from email.parser import Parser
from pathlib import Path
from typing import Iterable


PACKAGE_PREFIX = "onnxruntime_ep_openvino/"
EXPECTED_DISTRIBUTION = "onnxruntime-ep-openvino"
EXPECTED_VERSION = "1.8.1"
PLUGIN_NAME = "libonnxruntime_providers_openvino_plugin.so"
NOTICES_NAME = "third-party-programs.txt"
GPU_CACHE_NAME = "cache.json"
METADATA_SUFFIX = ".dist-info/METADATA"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_shared_library(name: str) -> bool:
    return name.endswith(".so") or ".so." in name


def extract(wheel: Path, output: Path, expected_sha256: str) -> list[str]:
    actual_sha256 = sha256_file(wheel)
    if actual_sha256.lower() != expected_sha256.lower():
        raise ValueError(f"Wheel SHA-256 mismatch: expected {expected_sha256}, got {actual_sha256}")

    output.mkdir(parents=True, exist_ok=True)
    written: list[str] = []
    with zipfile.ZipFile(wheel) as archive:
        names = set(archive.namelist())
        plugin_member = PACKAGE_PREFIX + PLUGIN_NAME
        notice_member = PACKAGE_PREFIX + NOTICES_NAME
        gpu_cache_member = PACKAGE_PREFIX + GPU_CACHE_NAME
        metadata_members = [name for name in names if name.endswith(METADATA_SUFFIX)]
        required = {plugin_member, notice_member, gpu_cache_member}
        missing = required - names
        if missing or len(metadata_members) != 1:
            raise ValueError(f"OpenVINO wheel is missing required package files: {sorted(missing)}")
        metadata_text = archive.read(metadata_members[0]).decode("utf-8")
        metadata = Parser().parsestr(metadata_text)
        if (
            (metadata.get("Name") or "").lower() != EXPECTED_DISTRIBUTION
            or metadata.get("Version") != EXPECTED_VERSION
            or metadata.get("License") != "MIT"
        ):
            raise ValueError("OpenVINO wheel metadata does not match the pinned package, version, and license")

        library_members: Iterable[str] = sorted(
            name
            for name in names
            if name.startswith(PACKAGE_PREFIX)
            and is_shared_library(Path(name).name)
            and not (
                Path(name).name.startswith(PLUGIN_NAME + ".")
            )
        )
        if plugin_member not in library_members:
            raise ValueError(f"OpenVINO wheel has no {PLUGIN_NAME}")

        for member in library_members:
            basename = Path(member).name
            if not basename or basename in {".", ".."}:
                raise ValueError(f"Unsafe shared-library member path: {member}")
            destination = output / basename
            destination.write_bytes(archive.read(member))
            written.append(basename)

        for member, destination_name in (
            (notice_member, "OpenVINO-Plugin-ThirdPartyNotices.txt"),
            (metadata_members[0], "OpenVINO-Plugin-METADATA.txt"),
            (gpu_cache_member, GPU_CACHE_NAME),
        ):
            (output / destination_name).write_bytes(archive.read(member))
            written.append(destination_name)

    return written


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wheel", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("sha256")
    args = parser.parse_args()
    files = extract(args.wheel, args.output_dir, args.sha256)
    print(f"Extracted {len(files)} OpenVINO EP runtime files to {args.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
