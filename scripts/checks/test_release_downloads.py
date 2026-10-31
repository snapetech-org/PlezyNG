#!/usr/bin/env python3
"""Keep official FFmpeg source downloads resilient to transient network resets."""

from __future__ import annotations

import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from urllib.error import HTTPError, URLError
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "release_all_platforms", ROOT / "scripts/release_all_platforms.py"
)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class InterruptedResponse:
    def __init__(self) -> None:
        self.reads = 0

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def read(self, size=-1):
        if self.reads == 0:
            self.reads += 1
            return b"partial archive"
        raise ConnectionResetError(104, "Connection reset by peer")


class ReleaseDownloadTests(unittest.TestCase):
    def test_retries_connection_reset_during_open(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "ffmpeg.tar.xz"
            with (
                patch.object(
                    release.urllib.request,
                    "urlopen",
                    side_effect=[
                        URLError(ConnectionResetError(104, "Connection reset by peer")),
                        io.BytesIO(b"verified archive bytes"),
                    ],
                ) as urlopen,
                patch.object(release.time, "sleep") as sleep,
            ):
                release.download("https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz", destination)

            self.assertEqual(destination.read_bytes(), b"verified archive bytes")
            self.assertFalse(destination.with_name(destination.name + ".part").exists())
            self.assertEqual(urlopen.call_count, 2)
            sleep.assert_called_once_with(release.DOWNLOAD_RETRY_INITIAL_DELAY_SECONDS)

    def test_retries_reset_and_replaces_partial_file_atomically(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "ffmpeg.tar.xz"
            with (
                patch.object(
                    release.urllib.request,
                    "urlopen",
                    side_effect=[InterruptedResponse(), io.BytesIO(b"verified archive bytes")],
                ) as urlopen,
                patch.object(release.time, "sleep") as sleep,
            ):
                release.download("https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz", destination)

            self.assertEqual(destination.read_bytes(), b"verified archive bytes")
            self.assertFalse(destination.with_name(destination.name + ".part").exists())
            self.assertEqual(urlopen.call_count, 2)
            sleep.assert_called_once_with(release.DOWNLOAD_RETRY_INITIAL_DELAY_SECONDS)

    def test_permanent_http_error_is_not_retried(self) -> None:
        error = HTTPError(
            "https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz",
            404,
            "Not Found",
            hdrs=None,
            fp=io.BytesIO(),
        )
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "ffmpeg.tar.xz"
            with (
                patch.object(release.urllib.request, "urlopen", side_effect=error) as urlopen,
                patch.object(release.time, "sleep") as sleep,
            ):
                with self.assertRaises(HTTPError):
                    release.download(
                        "https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz", destination
                    )

            urlopen.assert_called_once()
            sleep.assert_not_called()
            self.assertFalse(destination.with_name(destination.name + ".part").exists())


if __name__ == "__main__":
    unittest.main()
