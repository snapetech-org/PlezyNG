#!/usr/bin/env python3
"""Fetch and verify the complete offline runtime used by every Linux app build."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile

from maestro.safe_http import safe_urlopen

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "tools/dv-engine/offline-runtime.lock.json"
REQUIRED = ("plezyng-dv-convert", "bin/python3.12", "bin/ffmpeg", "bin/ffprobe",
            "bin/plezyng-dv-frames", "plugins/libfelbaker.so",
            "lib/python3.12/site-packages/vapoursynth/plugins/libffms2.so")


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify(root: Path, architecture: str) -> None:
    report = json.loads((root / "provenance.json").read_text())
    if report["architecture"] != architecture:
        raise ValueError("offline runtime architecture differs from the app")
    if report["lock"] != json.loads((ROOT / "tools/dv-engine/offline.lock.json").read_text()):
        raise ValueError("offline runtime source pins differ from the app lock")
    expected_machine = {"x86_64": 62, "aarch64": 183}[architecture]
    for relative, expected in report["files"].items():
        name = PurePosixPath(relative)
        if name.is_absolute() or ".." in name.parts:
            raise ValueError("invalid offline runtime manifest path")
        path = root / relative
        if not path.is_file() or path.is_symlink() or digest(path) != expected:
            raise ValueError(f"offline runtime file hash mismatch: {relative}")
        with path.open("rb") as stream:
            header = stream.read(20)
        if header.startswith(b"\x7fELF") and (header[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", header, 18)[0] != expected_machine):
            raise ValueError(f"wrong-architecture offline binary: {relative}")
    if set(REQUIRED) - set(report["files"]):
        raise ValueError("offline runtime is missing required dependencies")
    actual = {str(path.relative_to(root)) for path in root.rglob("*") if path.is_file()}
    if actual - set(report["files"]) - {"provenance.json", ".plezyng-download.json"}:
        raise ValueError("offline runtime contains unrecorded files")
    for relative in ("plezyng-dv-convert", "bin/python3.12", "bin/ffmpeg", "bin/ffprobe", "bin/plezyng-dv-frames"):
        if not os.access(root / relative, os.X_OK):
            raise ValueError(f"offline executable has no execute permission: {relative}")


def install(archive: Path, destination: Path, entry: dict, architecture: str) -> None:
    if digest(archive) != entry["checksum"]:
        raise ValueError("offline runtime archive checksum mismatch")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".dv-tools-", dir=destination.parent) as temporary:
        stage = Path(temporary)
        unpacked = stage / "runtime"
        unpacked.mkdir()
        plain = stage / "archive.tar"
        with plain.open("wb") as output:
            subprocess.run(["zstd", "-dc", str(archive)], check=True, stdout=output)
        with tarfile.open(plain) as source:
            for member in source.getmembers():
                name = PurePosixPath(member.name)
                if name.is_absolute() or ".." in name.parts or not (member.isfile() or member.isdir()):
                    raise ValueError("offline archive contains an unsafe path or link")
            source.extractall(unpacked, filter="data")
        verify(unpacked, architecture)
        (unpacked / ".plezyng-download.json").write_text(json.dumps(entry, sort_keys=True) + "\n")
        # A cache miss gets a new content-addressed directory. Preserve an
        # unexpected or modified existing tree instead of deleting it.
        if destination.exists():
            raise ValueError("offline destination already exists; preserve it and use a new cache path")
        shutil.move(unpacked, destination)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=LOCK)
    parser.add_argument("--dest", type=Path)
    parser.add_argument("--archive", type=Path, help="verify a pre-staged locked archive")
    args = parser.parse_args()
    lock = json.loads(args.lock.read_text())
    architecture = platform.machine()
    entry = lock["assets"][architecture]
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "plezyng/dv-tools"
    destination = (args.dest or cache / architecture / entry["checksum"]).absolute()
    if destination.exists():
        if json.loads((destination / ".plezyng-download.json").read_text()) != entry:
            raise ValueError("offline cache receipt does not match the release pin")
        verify(destination, architecture)
    elif args.archive:
        install(args.archive, destination, entry, architecture)
    else:
        with tempfile.NamedTemporaryFile(suffix=".tar.zst") as archive:
            url = lock["assetBase"] + "/" + entry["asset"]
            print("Fetching locked offline runtime: " + url, file=sys.stderr, flush=True)
            if url.startswith("https://github.com/snapetech-org/mpv-build/releases/download/"):
                from prepare_native_downloads import prepare_github_url
                prepare_github_url(url, entry["checksum"], Path(archive.name), Path.home() / ".cache/pleazyng-native-downloads")
            else:
                with safe_urlopen(url) as response:
                    shutil.copyfileobj(response, archive)
            archive.flush()
            install(Path(archive.name), destination, entry, architecture)
    print(destination)


if __name__ == "__main__":
    main()
