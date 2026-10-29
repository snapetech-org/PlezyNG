#!/usr/bin/env python3
"""Prepare the lockfile-pinned Flutter Whisper sources for webOS CMake."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import tarfile
import tempfile
import urllib.request
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[2]
LOCK_PATH = ROOT / "tools" / "webos" / "compatibility.json"
PUBSPEC_LOCK = ROOT / "pubspec.lock"
MAX_ARCHIVE_BYTES = 128 * 1024 * 1024
MAX_UNPACKED_BYTES = 1024 * 1024 * 1024
MAX_MEMBER_BYTES = 256 * 1024 * 1024
MAX_MEMBERS = 100_000


def locked_package() -> tuple[str, str, str]:
    try:
        compatibility = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
        runtime = compatibility["whisperRuntime"]
        package_name = runtime["package"]
        version = runtime["version"]
        expected_digest = runtime["archiveSha256"]
        url = runtime["archiveUrl"]
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
        raise ValueError("webOS Whisper source lock is malformed") from exc

    if package_name != "flutter_whisper_ggml":
        raise ValueError("webOS Whisper package name is not the reviewed package")
    if not re.fullmatch(r"\d+\.\d+\.\d+", str(version)):
        raise ValueError("webOS Whisper package version is malformed")
    if not re.fullmatch(r"[0-9a-f]{64}", str(expected_digest)):
        raise ValueError("webOS Whisper source digest is malformed")
    expected_url = f"https://pub.dev/api/archives/{package_name}-{version}.tar.gz"
    if url != expected_url:
        raise ValueError("webOS Whisper source URL does not match the package lock")

    try:
        lock_text = PUBSPEC_LOCK.read_text(encoding="utf-8")
    except OSError as exc:
        raise ValueError("cannot read pubspec.lock") from exc
    match = re.search(
        r"(?ms)^  flutter_whisper_ggml:\n(.*?)(?=^  [^ \n][^\n]*:\n|\Z)",
        lock_text,
    )
    if match is None:
        raise ValueError("flutter_whisper_ggml is missing from pubspec.lock")
    package = match.group(1)
    version_match = re.search(r'^    version: "([^\"]+)"$', package, re.M)
    digest_match = re.search(r"^      sha256: ([0-9a-f]{64})$", package, re.M)
    if version_match is None or version_match.group(1) != version:
        raise ValueError("pubspec.lock and the webOS Whisper version pin disagree")
    if digest_match is None or digest_match.group(1) != expected_digest:
        raise ValueError("pubspec.lock and the webOS Whisper archive digest disagree")
    return expected_url, str(version), str(expected_digest)


def download_archive(url: str, destination: Path, expected_digest: str) -> None:
    digest = hashlib.sha256()
    total = 0
    request = urllib.request.Request(url, headers={"User-Agent": "PlezyNG webOS source builder"})
    with urllib.request.urlopen(request, timeout=60) as response, destination.open("xb") as output:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_ARCHIVE_BYTES:
                raise ValueError("Whisper source archive exceeds the 128 MiB limit")
            digest.update(chunk)
            output.write(chunk)
    if total == 0 or digest.hexdigest() != expected_digest:
        destination.unlink(missing_ok=True)
        raise ValueError("flutter_whisper_ggml source archive digest mismatch")


def unpack_archive(archive_path: Path, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=False)
    try:
        with tarfile.open(archive_path, mode="r:gz") as archive:
            members = archive.getmembers()
            if not members or len(members) > MAX_MEMBERS:
                raise ValueError("Whisper source archive has an invalid member count")
            names = [
                member.name[:-1] if member.isdir() and member.name.endswith("/") else member.name
                for member in members
            ]
            paths = [PurePosixPath(name) for name in names]
            strip_root = all(path.parts and path.parts[0] == "package" for path in paths)
            seen: set[PurePosixPath] = set()
            unpacked = 0

            for member, name, path in zip(members, names, paths, strict=True):
                parts = path.parts[1:] if strip_root else path.parts
                if strip_root and not parts and member.isdir():
                    continue
                if (
                    path.is_absolute()
                    or path.as_posix() != name
                    or "\\" in name
                    or not parts
                    or any(part in ("", ".", "..") for part in parts)
                ):
                    raise ValueError("Whisper source archive contains an unsafe path")
                if member.issym() or member.islnk() or not (member.isdir() or member.isfile()):
                    raise ValueError("Whisper source archive contains an unsupported entry type")
                relative = PurePosixPath(*parts)
                if relative in seen:
                    raise ValueError("Whisper source archive contains a duplicate path")
                seen.add(relative)
                if member.size < 0 or member.size > MAX_MEMBER_BYTES:
                    raise ValueError("Whisper source archive contains an oversized member")
                unpacked += member.size
                if unpacked > MAX_UNPACKED_BYTES:
                    raise ValueError("Whisper source archive exceeds the 1 GiB expanded limit")

                target = destination.joinpath(*relative.parts)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    raise ValueError("Could not read a Whisper source archive entry")
                with source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
    except (OSError, tarfile.TarError) as exc:
        raise ValueError(f"cannot extract flutter_whisper_ggml sources: {exc}") from exc

    if not (destination / "src/CMakeLists.txt").is_file() or not (
        destination / "whisper/v1.9.2/include/whisper.h"
    ).is_file():
        raise ValueError("flutter_whisper_ggml archive is missing its pinned native sources")
    return destination


def prepare(destination: Path) -> Path:
    url, version, expected_digest = locked_package()
    if destination.exists() or destination.is_symlink():
        raise ValueError(f"refusing to reuse Whisper source destination: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".plezyng-whisper-", dir=destination.parent) as temporary:
        temporary_root = Path(temporary)
        archive = temporary_root / f"flutter_whisper_ggml-{version}.tar.gz"
        download_archive(url, archive, expected_digest)
        package = unpack_archive(archive, temporary_root / "package")
        package.rename(destination)
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", required=True, type=Path)
    args = parser.parse_args()
    try:
        package = prepare(args.destination)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    print(package)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
