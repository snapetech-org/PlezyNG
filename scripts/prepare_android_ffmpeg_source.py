#!/usr/bin/env python3
"""Download and verify the pinned FFmpeg headers source used by Android builds."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import ProxyHandler, Request, build_opener

from prepare_android_sdk import proxy_parts


ROOT = Path(__file__).resolve().parents[1]
GRADLE_FILE = ROOT / "android/app/build.gradle.kts"
MAX_ATTEMPTS = 5


def pinned_source() -> tuple[str, str, str]:
    source = GRADLE_FILE.read_text(encoding="utf-8")
    version_match = re.search(r'^val mpvFfmpegVersion = "([0-9.]+)"$', source, re.MULTILINE)
    digest_match = re.search(r'^val mpvFfmpegSourceSha256 = "([0-9a-f]{64})"$', source, re.MULTILINE)
    if version_match is None or digest_match is None:
        raise ValueError("Android Gradle file is missing the pinned FFmpeg version or SHA-256")
    version = version_match.group(1)
    digest = digest_match.group(1)
    url = f"https://ffmpeg.org/releases/ffmpeg-{version}.tar.xz"
    return version, digest, url


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url: str, destination: Path, expected_sha256: str) -> None:
    parsed = urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname != "ffmpeg.org":
        raise ValueError(f"Refusing non-official FFmpeg source URL: {url}")

    proxy_host, proxy_port = proxy_parts(dict(os.environ))
    proxy = f"http://{proxy_host}:{proxy_port}"
    opener = build_opener(ProxyHandler({"https": proxy}))
    request = Request(url, headers={"User-Agent": "PlezyNG-Android-FFmpeg/1"})
    partial = destination.with_name(destination.name + ".part")

    for attempt in range(1, MAX_ATTEMPTS + 1):
        last_exception: BaseException | None = None
        try:
            with opener.open(request, timeout=90) as response:
                final = urlsplit(response.geturl())
                if final.scheme != "https" or final.hostname != "ffmpeg.org":
                    raise ValueError(f"FFmpeg source redirected to an unapproved host: {final.hostname}")
                with partial.open("wb") as output:
                    shutil.copyfileobj(response, output)
        except HTTPError as error:
            partial.unlink(missing_ok=True)
            if error.code not in (408, 429) and not 500 <= error.code < 600:
                raise RuntimeError(f"FFmpeg source download returned HTTP {error.code} {error.reason}") from error
            last_exception = error
        except (URLError, TimeoutError, ConnectionError, OSError) as error:
            partial.unlink(missing_ok=True)
            last_exception = error

        if last_exception is None:
            actual_sha256 = sha256_file(partial)
            if actual_sha256 != expected_sha256:
                partial.unlink(missing_ok=True)
                raise RuntimeError(
                    f"FFmpeg source SHA-256 mismatch: expected {expected_sha256}, got {actual_sha256}"
                )
            partial.replace(destination)
            return

        if attempt == MAX_ATTEMPTS:
            raise RuntimeError(
                f"FFmpeg source download failed after {attempt} attempts: {last_exception}"
            ) from last_exception
        delay = 3 * attempt
        print(
            f"Transient FFmpeg source download failure "
            f"(attempt {attempt}/{MAX_ATTEMPTS}); retrying in {delay}s: {last_exception}",
            file=sys.stderr,
            flush=True,
        )
        time.sleep(delay)


def prepare(destination: Path) -> None:
    version, expected_sha256, url = pinned_source()
    destination = destination.expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)

    if destination.is_file():
        actual_sha256 = sha256_file(destination)
        if actual_sha256 == expected_sha256:
            print(f"Using cached FFmpeg {version} source archive with verified SHA-256.")
        else:
            print("Cached FFmpeg source archive has a stale SHA-256; downloading the pinned archive.")
            destination.unlink()
            download(url, destination, expected_sha256)
    else:
        download(url, destination, expected_sha256)

    env_file = os.environ.get("GITHUB_ENV")
    if env_file:
        with Path(env_file).open("a", encoding="utf-8") as output:
            output.write(f"PLEZYNG_FFMPEG_SOURCE_ARCHIVE={destination}\n")
    print(f"Verified FFmpeg {version} source archive: {destination}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="cache file path for the pinned FFmpeg source archive")
    args = parser.parse_args()
    try:
        prepare(args.archive)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
