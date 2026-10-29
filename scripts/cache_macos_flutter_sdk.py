#!/usr/bin/env python3
"""Prepare the pinned Apple Flutter SDK in the Mac JIT job's local APFS temp directory."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid


MANIFEST_URL = "https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json"
ARCHIVE_BASE_URL = "https://storage.googleapis.com/flutter_infra_release/releases/"
SEGMENT_BYTES = 64 * 1024 * 1024
MAX_WORKERS = 16
MAX_ATTEMPTS = 8
READ_SIZE = 1024 * 1024
# Keep this per-job SDK cache under RUNNER_TEMP so the worker removes it after
# each job. The post-install check enforces the 30 GiB reserve; the 9 GiB
# preflight budget leaves room for the Flutter archive and extracted SDK while
# tolerating small APFS free-space differences around the broker's 40 GiB idle
# threshold.
MIN_FREE_BYTES = 30 * 1024**3
INSTALL_HEADROOM_BYTES = 9 * 1024**3
CONTENT_RANGE_RE = re.compile(r"^bytes (\d+)-(\d+)/(\d+)$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def release_metadata(manifest: dict, version: str) -> dict[str, str]:
    """Select the exact stable Apple Silicon SDK release from Flutter's manifest."""
    matches = [
        release
        for release in manifest.get("releases", [])
        if release.get("channel") == "stable"
        and release.get("version") == version
        and release.get("dart_sdk_arch") == "arm64"
    ]
    if len(matches) != 1:
        raise ValueError(f"expected one stable macOS arm64 Flutter {version} release")
    release = matches[0]
    archive = release.get("archive")
    digest = release.get("sha256")
    cache_hash = release.get("hash")
    if not isinstance(archive, str) or not archive.startswith("stable/macos/"):
        raise ValueError("Flutter manifest returned an unexpected macOS archive path")
    if ".." in Path(archive).parts or not archive.endswith("-stable.zip"):
        raise ValueError("Flutter manifest returned an unsafe macOS archive path")
    if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
        raise ValueError("Flutter manifest returned an invalid archive SHA-256")
    if not isinstance(cache_hash, str) or not re.fullmatch(r"[0-9a-f]{40,64}", cache_hash):
        raise ValueError("Flutter manifest returned an invalid release hash")
    return {
        "version": version,
        "archive": archive,
        "archive_url": ARCHIVE_BASE_URL + archive,
        "sha256": digest,
        "release_hash": cache_hash,
        "archive_name": Path(archive).name,
    }


def fetch_release_metadata(version: str) -> dict[str, str]:
    request = urllib.request.Request(
        MANIFEST_URL,
        headers={"User-Agent": "plezyng-macos-flutter-cache/1"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        manifest = json.load(response)
    if not isinstance(manifest, dict):
        raise ValueError("Flutter release manifest is not a JSON object")
    return release_metadata(manifest, version)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(READ_SIZE), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _require_regular_or_missing(path: Path) -> None:
    if path.is_symlink():
        raise RuntimeError(f"refusing a symlink in the Flutter cache: {path}")
    if path.exists() and not path.is_file() and not path.is_dir():
        raise RuntimeError(f"unexpected filesystem object in the Flutter cache: {path}")


def _ensure_private_directory(path: Path) -> Path:
    home = Path.home().resolve()
    expanded = path.expanduser()
    if not expanded.is_absolute():
        raise RuntimeError("Flutter cache path must be absolute")
    lexical = Path(os.path.abspath(expanded))
    resolved = lexical.resolve(strict=False)
    if not lexical.is_relative_to(home) or not resolved.is_relative_to(home):
        raise RuntimeError("Flutter cache must stay inside the JIT user's home directory")
    cursor = home
    for part in lexical.relative_to(home).parts:
        cursor = cursor / part
        if cursor.is_symlink():
            raise RuntimeError(f"refusing a symlink in the Flutter cache path: {cursor}")
    expanded.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = expanded.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise RuntimeError("Flutter cache directory must be owned by the JIT user")
    if stat.S_IMODE(info.st_mode) & 0o077:
        expanded.chmod(0o700)
    return expanded


@contextmanager
def _cache_lock(cache_root: Path):
    """Serialize setup jobs that share the Mac user's persistent SDK cache."""
    lock_path = cache_root / ".flutter-sdk-cache.lock"
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(lock_path, flags, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise RuntimeError("Flutter cache lock must be a regular file owned by the JIT user")
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def cache_is_valid(cache_path: Path, version: str, sha256: str) -> bool:
    marker = cache_path / ".plezy-flutter-sdk.json"
    flutter = cache_path / "flutter" / "bin" / "flutter"
    if cache_path.is_symlink() or marker.is_symlink() or flutter.is_symlink():
        return False
    if not cache_path.is_dir() or not marker.is_file() or not flutter.is_file() or not os.access(flutter, os.X_OK):
        return False
    try:
        metadata = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return metadata.get("version") == version and metadata.get("sha256") == sha256


def require_per_job_cache_root(cache_root: Path, runner_temp: str | None) -> Path:
    if not runner_temp:
        raise RuntimeError("RUNNER_TEMP is required for the per-job Flutter SDK cache")
    temporary = Path(runner_temp).expanduser().resolve()
    root = Path(os.path.abspath(cache_root.expanduser()))
    if not root.resolve(strict=False).is_relative_to(temporary):
        raise RuntimeError("Flutter SDK cache must stay inside this JIT job's RUNNER_TEMP")
    return root


def require_install_headroom(free_bytes: int) -> None:
    required_bytes = MIN_FREE_BYTES + INSTALL_HEADROOM_BYTES
    if free_bytes < required_bytes:
        raise RuntimeError(
            f"Flutter SDK install needs {required_bytes / 1024**3:.0f} GiB free "
            f"({MIN_FREE_BYTES / 1024**3:.0f} GiB reserved plus "
            f"{INSTALL_HEADROOM_BYTES / 1024**3:.0f} GiB install headroom); "
            f"Mac JIT has {free_bytes / 1024**3:.1f} GiB free"
        )


def _archive_length(url: str) -> int:
    request = urllib.request.Request(
        url,
        method="HEAD",
        headers={
            "Accept-Encoding": "identity",
            "User-Agent": "plezyng-macos-flutter-cache/1",
        },
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        length = int(response.headers.get("Content-Length", "0"))
        ranges = response.headers.get("Accept-Ranges", "").lower()
    if length <= 0 or ranges != "bytes":
        raise RuntimeError("Flutter archive server did not provide a ranged download")
    return length


def _download_range(url: str, path: Path, start: int, end: int, total: int) -> Path:
    expected_size = end - start + 1
    _require_regular_or_missing(path)
    if path.exists() and path.stat().st_size > expected_size:
        path.unlink()

    for attempt in range(MAX_ATTEMPTS):
        current_size = path.stat().st_size if path.exists() else 0
        if current_size == expected_size:
            return path
        offset = start + current_size
        request = urllib.request.Request(
            url,
            headers={
                "Accept-Encoding": "identity",
                "Range": f"bytes={offset}-{end}",
                "User-Agent": "plezyng-macos-flutter-cache/1",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                content_range = response.headers.get("Content-Range", "")
                match = CONTENT_RANGE_RE.fullmatch(content_range)
                if response.getcode() != 206 or not match:
                    raise RuntimeError("Flutter archive server ignored a byte-range request")
                if tuple(map(int, match.groups())) != (offset, end, total):
                    raise RuntimeError("Flutter archive server returned the wrong byte range")
                with path.open("ab" if current_size else "wb") as output:
                    while chunk := response.read(READ_SIZE):
                        output.write(chunk)
            actual_size = path.stat().st_size
            if actual_size == expected_size:
                return path
            raise OSError(f"short range download: received {actual_size} of {expected_size} bytes")
        except (OSError, urllib.error.URLError, RuntimeError) as exc:
            if attempt + 1 == MAX_ATTEMPTS:
                raise RuntimeError(f"Flutter archive range {start}-{end} failed after retries: {exc}") from exc
            delay = min(2**attempt, 30)
            print(
                f"Flutter archive range {start}-{end} retry {attempt + 1}/{MAX_ATTEMPTS} "
                f"in {delay}s: {exc}",
                file=sys.stderr,
                flush=True,
            )
            time.sleep(delay)
    raise AssertionError("unreachable download retry state")


def download_archive(
    url: str,
    expected_sha256: str,
    destination: Path,
    *,
    segment_bytes: int = SEGMENT_BYTES,
    max_workers: int = MAX_WORKERS,
) -> Path:
    if not SHA256_RE.fullmatch(expected_sha256):
        raise ValueError("invalid expected Flutter archive SHA-256")
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    _require_regular_or_missing(destination)
    if destination.exists() and not destination.is_file():
        raise RuntimeError(f"Flutter archive destination is not a regular file: {destination}")
    if destination.is_file() and _sha256(destination) == expected_sha256:
        return destination
    if destination.exists():
        destination.unlink()

    total = _archive_length(url)
    ranges = [
        (start, min(start + segment_bytes - 1, total - 1))
        for start in range(0, total, segment_bytes)
    ]
    parts = [destination.with_name(f".{destination.name}.part-{index:04d}") for index in range(len(ranges))]
    for part in parts:
        _require_regular_or_missing(part)
        if part.exists() and not part.is_file():
            raise RuntimeError(f"Flutter archive range is not a regular file: {part}")
    print(
        f"Downloading Flutter macOS SDK in {len(ranges)} resumable ranges "
        f"({total / 1024**3:.2f} GiB, {min(max_workers, len(ranges))} connections).",
        flush=True,
    )
    with ThreadPoolExecutor(max_workers=min(max_workers, len(ranges))) as executor:
        futures = [
            executor.submit(_download_range, url, part, start, end, total)
            for part, (start, end) in zip(parts, ranges, strict=True)
        ]
        for future in as_completed(futures):
            future.result()

    assembled = destination.with_name(f".{destination.name}.assembling")
    _require_regular_or_missing(assembled)
    if assembled.exists() and not assembled.is_file():
        raise RuntimeError(f"Flutter archive assembly path is not a regular file: {assembled}")
    if assembled.exists():
        assembled.unlink()
    digest = hashlib.sha256()
    try:
        with assembled.open("wb") as output:
            for part in parts:
                with part.open("rb") as source:
                    while chunk := source.read(8 * READ_SIZE):
                        output.write(chunk)
                        digest.update(chunk)
        if digest.hexdigest() != expected_sha256:
            raise RuntimeError("downloaded Flutter archive did not match the manifest SHA-256")
        os.replace(assembled, destination)
    except Exception:
        assembled.unlink(missing_ok=True)
        for part in parts:
            part.unlink(missing_ok=True)
        raise
    for part in parts:
        part.unlink(missing_ok=True)
    return destination


def _extract_sdk_archive(archive: Path, cache_root: Path, version: str, sha256: str) -> Path:
    cache_path = cache_root / f"stable-{version}-arm64"
    if cache_path.is_symlink():
        raise RuntimeError(f"refusing a symlink in the Flutter SDK cache: {cache_path}")
    cache_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    staging = cache_root / f".extract-{version}-{uuid.uuid4().hex}"
    staging.mkdir(mode=0o700)
    try:
        subprocess.run(
            ["/usr/bin/unzip", "-q", "-o", str(archive), "-d", str(staging)],
            check=True,
        )
        flutter = staging / "flutter" / "bin" / "flutter"
        if not flutter.is_file():
            raise RuntimeError("verified Flutter archive did not contain flutter/bin/flutter")
        marker = staging / ".plezy-flutter-sdk.json"
        marker.write_text(
            json.dumps({"version": version, "sha256": sha256}, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        marker.chmod(0o600)
        if cache_path.exists():
            stale = cache_root / f".stale-{cache_path.name}-{uuid.uuid4().hex}"
            os.replace(cache_path, stale)
            print(f"Preserving incomplete Flutter cache at {stale}", flush=True)
        os.replace(staging, cache_path)
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return cache_path


def ensure_sdk(version: str, cache_root: Path) -> Path:
    if sys.platform != "darwin" or os.uname().machine != "arm64":
        raise RuntimeError("the pinned macOS Flutter cache can only be prepared on Apple Silicon")
    cache_root = require_per_job_cache_root(cache_root, os.environ.get("RUNNER_TEMP"))
    metadata = fetch_release_metadata(version)
    cache_root = _ensure_private_directory(cache_root)
    with _cache_lock(cache_root):
        cache_path = cache_root / f"stable-{version}-arm64"
        if cache_is_valid(cache_path, version, metadata["sha256"]):
            if shutil.disk_usage(cache_root).free < MIN_FREE_BYTES:
                raise RuntimeError("Mac JIT APFS free space fell below 30 GiB")
            print(f"Reusing verified Flutter {version} SDK from local APFS cache.", flush=True)
            return cache_path

        free_bytes = shutil.disk_usage(cache_root).free
        require_install_headroom(free_bytes)
        downloads = _ensure_private_directory(cache_root / ".downloads")
        archive = downloads / metadata["archive_name"]
        download_archive(metadata["archive_url"], metadata["sha256"], archive)
        cache_path = _extract_sdk_archive(archive, cache_root, version, metadata["sha256"])
        archive.unlink(missing_ok=True)
        for part in downloads.glob(f".{archive.name}.part-*"):
            if part.is_file() and not part.is_symlink():
                part.unlink()
        if shutil.disk_usage(cache_root).free < MIN_FREE_BYTES:
            raise RuntimeError("Mac JIT APFS free space fell below 30 GiB after Flutter SDK installation")
        print(f"Installed verified Flutter {version} SDK in local APFS cache.", flush=True)
        return cache_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    metadata_parser = subparsers.add_parser("metadata")
    metadata_parser.add_argument("--version", required=True)
    ensure_parser = subparsers.add_parser("ensure")
    ensure_parser.add_argument("--version", required=True)
    ensure_parser.add_argument("--cache-root", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.command == "metadata":
        metadata = fetch_release_metadata(args.version)
        print(f"cache_key=flutter-macos-stable-{args.version}-arm64-{metadata['release_hash']}")
        print(f"archive_url={metadata['archive_url']}")
        print(f"sha256={metadata['sha256']}")
        print(f"archive_name={metadata['archive_name']}")
        return 0
    ensure_sdk(args.version, args.cache_root)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"Flutter macOS SDK cache failed ({type(exc).__name__}): {exc}", file=sys.stderr)
        raise SystemExit(1)
