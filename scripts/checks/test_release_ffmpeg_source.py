#!/usr/bin/env python3
"""Keep cached FFmpeg source reuse behind the existing signature gate."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release_all_platforms", ROOT / "scripts/release_all_platforms.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class FfmpegSourceCacheTest(unittest.TestCase):
    def test_cached_source_is_copied_and_still_requires_the_pinned_signature(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / "cache"
            scratch = root / "scratch"
            cache.mkdir()
            archive = b"signed FFmpeg source"
            (cache / "ffmpeg-9.0.2.tar.xz").write_bytes(archive)
            (cache / "ffmpeg-9.0.2.tar.xz.asc").write_text("signature", encoding="utf-8")
            (cache / "ffmpeg-devel.asc").write_text("public key", encoding="utf-8")

            def fake_command(args, **kwargs):
                stdout = ""
                if "--verify" in args:
                    stdout = f"[GNUPG:] VALIDSIG {release.FFMPEG_SIGNING_FINGERPRINT} "
                return subprocess.CompletedProcess(args, 0, stdout, "")

            with (
                patch.object(release, "download", side_effect=AssertionError("cache should avoid downloads")),
                patch.object(release, "command", side_effect=fake_command) as command,
                patch.object(release.shutil, "which", return_value="/usr/bin/gpg"),
            ):
                version, digest = release.verified_ffmpeg_source("n9.0.2", scratch, source_cache=cache)

            self.assertEqual(version, "9.0.2")
            self.assertEqual(digest, release.hashlib.sha256(archive).hexdigest())
            self.assertEqual(command.call_count, 2)
            self.assertEqual((scratch / "ffmpeg-9.0.2.tar.xz").read_bytes(), archive)
            self.assertEqual((scratch / "ffmpeg-9.0.2.tar.xz.asc").read_text(encoding="utf-8"), "signature")
            self.assertEqual((scratch / "ffmpeg-devel.asc").read_text(encoding="utf-8"), "public key")

    def test_incomplete_cache_fails_before_signature_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / "cache"
            cache.mkdir()
            (cache / "ffmpeg-9.0.2.tar.xz").write_bytes(b"archive")
            (cache / "ffmpeg-9.0.2.tar.xz.asc").write_text("signature", encoding="utf-8")

            with patch.object(release, "command") as command:
                with self.assertRaisesRegex(release.ReleaseError, "missing required file: ffmpeg-devel.asc"):
                    release.verified_ffmpeg_source("n9.0.2", root / "scratch", source_cache=cache)
                command.assert_not_called()

    def test_cached_source_with_an_unpinned_signer_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / "cache"
            cache.mkdir()
            (cache / "ffmpeg-9.0.2.tar.xz").write_bytes(b"archive")
            (cache / "ffmpeg-9.0.2.tar.xz.asc").write_text("signature", encoding="utf-8")
            (cache / "ffmpeg-devel.asc").write_text("public key", encoding="utf-8")

            def wrong_signer(args, **kwargs):
                stdout = "[GNUPG:] VALIDSIG " + "0" * 40 if "--verify" in args else ""
                return subprocess.CompletedProcess(args, 0, stdout, "")

            with (
                patch.object(release, "command", side_effect=wrong_signer),
                patch.object(release.shutil, "which", return_value="/usr/bin/gpg"),
            ):
                with self.assertRaisesRegex(release.ReleaseError, "pinned official signing key"):
                    release.verified_ffmpeg_source("n9.0.2", root / "scratch", source_cache=cache)


if __name__ == "__main__":
    unittest.main()
