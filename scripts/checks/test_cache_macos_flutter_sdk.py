from __future__ import annotations

from hashlib import sha256
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import stat
import sys
import tempfile
import threading
import unittest
from zipfile import ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from scripts.cache_macos_flutter_sdk import (
    _extract_sdk_archive,
    cache_is_valid,
    download_archive,
    release_metadata,
)


class FlutterSdkCacheTest(unittest.TestCase):
    def test_selects_exact_stable_macos_arm64_release(self) -> None:
        manifest = {
            "releases": [
                {
                    "channel": "stable",
                    "version": "3.47.1",
                    "dart_sdk_arch": "arm64",
                    "archive": "stable/macos/flutter_macos_arm64_3.47.1-stable.zip",
                    "sha256": "a" * 64,
                    "hash": "b" * 40,
                },
                {
                    "channel": "stable",
                    "version": "3.47.1",
                    "dart_sdk_arch": "x64",
                    "archive": "stable/macos/flutter_macos_x64_3.47.1-stable.zip",
                    "sha256": "c" * 64,
                    "hash": "d" * 40,
                },
            ]
        }

        metadata = release_metadata(manifest, "3.47.1")

        self.assertEqual(metadata["archive_name"], "flutter_macos_arm64_3.47.1-stable.zip")
        self.assertEqual(metadata["sha256"], "a" * 64)
        self.assertTrue(metadata["archive_url"].endswith(metadata["archive"]))

    def test_rejects_unsafe_archive_path(self) -> None:
        manifest = {
            "releases": [
                {
                    "channel": "stable",
                    "version": "3.47.1",
                    "dart_sdk_arch": "arm64",
                    "archive": "stable/macos/../../unexpected.zip",
                    "sha256": "a" * 64,
                    "hash": "b" * 40,
                }
            ]
        }

        with self.assertRaisesRegex(ValueError, "unsafe"):
            release_metadata(manifest, "3.47.1")

    def test_parallel_ranges_are_resumed_and_reassembled(self) -> None:
        payload = bytes(range(251)) * 701

        class RangeHandler(BaseHTTPRequestHandler):
            def do_HEAD(self) -> None:
                self.send_response(200)
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Accept-Ranges", "bytes")
                self.end_headers()

            def do_GET(self) -> None:
                value = self.headers.get("Range", "")
                start_text, end_text = value.removeprefix("bytes=").split("-", 1)
                start, end = int(start_text), int(end_text)
                content = payload[start : end + 1]
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(payload)}")
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)

            def log_message(self, format: str, *args: object) -> None:
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), RangeHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.addCleanup(thread.join, 2)

        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "flutter.zip"
            result = download_archive(
                f"http://127.0.0.1:{server.server_port}/flutter.zip",
                sha256(payload).hexdigest(),
                destination,
                segment_bytes=32_000,
                max_workers=4,
            )

            self.assertEqual(result.read_bytes(), payload)
            self.assertEqual(list(Path(temporary).glob(".*.part-*")), [])

    def test_verified_archive_is_extracted_and_marked_for_reuse(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "flutter.zip"
            with ZipFile(archive, "w") as bundle:
                flutter = ZipInfo("flutter/bin/flutter")
                flutter.external_attr = (stat.S_IFREG | 0o755) << 16
                bundle.writestr(flutter, b"#!/bin/sh\nexit 0\n")
            digest = sha256(archive.read_bytes()).hexdigest()

            cache = _extract_sdk_archive(archive, root / "cache", "3.47.1", digest)

            self.assertTrue(cache_is_valid(cache, "3.47.1", digest))
            self.assertTrue((cache / "flutter" / "bin" / "flutter").stat().st_mode & stat.S_IXUSR)
            self.assertFalse(cache_is_valid(cache, "3.47.1", "0" * 64))


if __name__ == "__main__":
    unittest.main()
