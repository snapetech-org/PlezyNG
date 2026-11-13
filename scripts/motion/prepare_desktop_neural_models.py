#!/usr/bin/env python3
"""Fetch and verify the pinned desktop ANVIL graphs before CMake packaging."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from urllib.parse import quote


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "assets/motion_models/manifest.json"
DESKTOP_MODELS = ("anvil-s-1080p", "anvil-m-1080p")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def model_url(model: dict) -> str:
    source = model.get("source")
    revision = model.get("sourceRevision")
    filename = model.get("file")
    if (not isinstance(source, str) or not source.startswith("https://huggingface.co/")
            or not isinstance(revision, str) or len(revision) != 40
            or not all(character in "0123456789abcdef" for character in revision)
            or not isinstance(filename, str) or Path(filename).name != filename):
        raise ValueError("Desktop model manifest has an invalid immutable source")
    return f"{source.rstrip('/')}/resolve/{revision}/onnx/{quote(filename)}"


def fetch_model(model_id: str, model: dict, destination: Path, curl: str) -> Path:
    filename = model.get("file")
    expected_bytes = model.get("bytes")
    expected_sha256 = model.get("sha256")
    if (not isinstance(filename, str) or Path(filename).name != filename
            or not isinstance(expected_bytes, int) or expected_bytes <= 0
            or not isinstance(expected_sha256, str) or len(expected_sha256) != 64
            or not all(character in "0123456789abcdef" for character in expected_sha256)):
        raise ValueError(f"Desktop model manifest entry is invalid: {model_id}")

    target = destination / filename
    if target.is_symlink():
        raise ValueError(f"Refusing linked model artifact: {target}")
    if target.is_file():
        if target.stat().st_size == expected_bytes and sha256(target) == expected_sha256:
            print(f"Reusing verified desktop model: {filename}", flush=True)
            return target
        raise ValueError(f"Existing desktop model cache failed its pinned size or SHA-256: {target}")

    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{filename}.", suffix=".partial", dir=destination)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        subprocess.run(
            [curl, "--fail", "--location", "--silent", "--show-error", "--retry", "3",
             "--connect-timeout", "20", "--max-time", "600", "--output", str(temporary),
             model_url(model)],
            check=True,
            timeout=660,
        )
        if temporary.stat().st_size != expected_bytes or sha256(temporary) != expected_sha256:
            raise ValueError(f"Downloaded desktop model failed its pinned size or SHA-256: {filename}")
        temporary.replace(target)
        print(f"Verified desktop model: {filename} ({expected_bytes} bytes, SHA-256 {expected_sha256})", flush=True)
        return target
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, required=True,
                        help="directory shared with the Windows or Linux CMake install")
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    models = manifest.get("models")
    if not isinstance(models, dict):
        raise ValueError("Desktop model manifest has no model map")
    missing = [model_id for model_id in DESKTOP_MODELS if not isinstance(models.get(model_id), dict)]
    if missing:
        raise ValueError(f"Desktop model manifest entries are missing: {missing}")
    curl = shutil.which("curl.exe") or shutil.which("curl")
    if not curl:
        raise ValueError("The build host has no curl executable")
    destination = args.destination.expanduser()
    if destination.is_symlink():
        raise ValueError(f"Refusing linked desktop model destination: {destination}")
    destination = destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    for model_id in DESKTOP_MODELS:
        fetch_model(model_id, models[model_id], destination, curl)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
