from __future__ import annotations

import builtins
from contextlib import ExitStack
from hashlib import sha256
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import stat
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from zipfile import ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from scripts.cache_macos_flutter_sdk import (
    INSTALL_SAFETY_MARGIN_BYTES,
    MIN_FREE_BYTES,
    _archive_uncompressed_size,
    _extract_sdk_archive,
    cache_is_valid,
    download_archive,
    ensure_sdk,
    require_install_headroom,
    require_per_job_cache_root,
    release_metadata,
)


class FlutterSdkCacheTest(unittest.TestCase):
    def test_measured_peaks_fit_small_local_reserve(self) -> None:
        gib = 1024**3
        self.assertEqual(MIN_FREE_BYTES, 4 * gib)
        self.assertEqual(INSTALL_SAFETY_MARGIN_BYTES, 4 * gib // 5)
        archive_size = int(2.2 * gib)
        expanded_size = 4 * gib
        free_at_start = 11 * gib
        require_install_headroom(free_at_start, archive_size * 2, "download")
        require_install_headroom(free_at_start - archive_size, expanded_size, "extraction")
        with self.assertRaisesRegex(RuntimeError, "extraction needs"):
            require_install_headroom(free_at_start - archive_size, expanded_size + gib, "extraction")

    def test_each_phase_retains_the_reserve_and_margin(self) -> None:
        for phase in ("download", "extraction"):
            with self.subTest(phase=phase):
                transient = 4 * 1024**3
                threshold = MIN_FREE_BYTES + transient + INSTALL_SAFETY_MARGIN_BYTES
                require_install_headroom(threshold, transient, phase)
                with self.assertRaisesRegex(RuntimeError, phase + " needs"):
                    require_install_headroom(threshold - 1, transient, phase)
        for invalid in (-1, 0.5, None, True):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                require_install_headroom(40 * 1024**3, invalid, "download")

    def test_flutter_sdk_cache_must_be_inside_the_current_job_temp_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            runner_temp = Path(temporary).resolve() / "runner-temp"
            runner_temp.mkdir()
            cache = runner_temp / "flutter-sdk"

            self.assertEqual(
                require_per_job_cache_root(cache, str(runner_temp)),
                cache.resolve(),
            )
            with self.assertRaisesRegex(RuntimeError, "RUNNER_TEMP"):
                require_per_job_cache_root(Path(temporary) / "persistent-cache", str(runner_temp))
            with self.assertRaisesRegex(RuntimeError, "RUNNER_TEMP"):
                require_per_job_cache_root(cache, None)

    def test_insufficient_extraction_space_stops_before_installing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            root = Path(temporary).resolve()
            metadata = {
                "archive_url": "https://unused.invalid/sdk.zip",
                "archive_name": "sdk.zip",
                "sha256": "a" * 64,
            }
            module = "scripts.cache_macos_flutter_sdk."
            stack.enter_context(patch(module + "sys.platform", "darwin"))
            stack.enter_context(patch(module + "Path.home", return_value=root))
            stack.enter_context(patch(module + "os.uname", return_value=SimpleNamespace(machine="arm64")))
            stack.enter_context(patch.dict("os.environ", {"RUNNER_TEMP": temporary}))
            stack.enter_context(patch(module + "fetch_release_metadata", return_value=metadata))
            stack.enter_context(patch(module + "_archive_length", return_value=2 * 1024**3))
            stack.enter_context(patch(module + "download_archive", return_value=root / "sdk.zip"))
            stack.enter_context(patch(module + "_archive_uncompressed_size", return_value=6 * 1024**3))
            stack.enter_context(patch(module + "shutil.disk_usage", side_effect=[
                SimpleNamespace(free=12 * 1024**3),
                SimpleNamespace(free=10 * 1024**3),
            ]))
            extract = stack.enter_context(patch(module + "_extract_sdk_archive"))
            with self.assertRaisesRegex(RuntimeError, "extraction needs"):
                ensure_sdk("3.47.1", root / "flutter-cache")
            extract.assert_not_called()

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
        head_requests = []

        class RangeHandler(BaseHTTPRequestHandler):
            def do_HEAD(self) -> None:
                head_requests.append(self.path)
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
            for index, expected_size in enumerate((None, len(payload))):
                with self.subTest(expected_size=expected_size):
                    destination = Path(temporary) / f"flutter-{index}.zip"
                    # The Mac's Python 3.9 zip() does not accept keyword args.
                    with patch(
                        "scripts.cache_macos_flutter_sdk.zip",
                        side_effect=lambda *iterables: builtins.zip(*iterables),
                        create=True,
                    ):
                        result = download_archive(
                            f"http://127.0.0.1:{server.server_port}/flutter.zip",
                            sha256(payload).hexdigest(),
                            destination,
                            segment_bytes=32_000,
                            max_workers=4,
                            expected_size=expected_size,
                        )
                    self.assertEqual(result.read_bytes(), payload)
                    self.assertEqual(list(Path(temporary).glob(".*.part-*")), [])
            self.assertEqual(len(head_requests), 1, "the preflight size must avoid a second HEAD")

    def test_invalid_download_size_never_starts_a_network_request(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            for invalid in (0, -1, True, 1.5):
                with self.subTest(invalid=invalid), patch(
                    "scripts.cache_macos_flutter_sdk._archive_length",
                    side_effect=AssertionError("unexpected network request"),
                ), self.assertRaises(ValueError):
                    download_archive("https://unused.invalid", "a" * 64, Path(temporary) / "sdk.zip", expected_size=invalid)

    def test_expanded_size_uses_uncompressed_members_and_rejects_invalid_zip(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "sdk.zip"
            with ZipFile(archive, "w") as bundle:
                bundle.writestr("flutter/first", b"first")
                bundle.writestr("flutter/second", b"second")
            self.assertEqual(_archive_uncompressed_size(archive), len(b"firstsecond"))
            archive.write_bytes(b"not a ZIP")
            with self.assertRaisesRegex(RuntimeError, "not a valid ZIP"):
                _archive_uncompressed_size(archive)

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
