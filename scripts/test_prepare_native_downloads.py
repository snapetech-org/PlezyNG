import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import prepare_native_downloads as downloads


class NativeDownloadsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.content = b"verified native asset fixture"
        self.digest = hashlib.sha256(self.content).hexdigest()
        self.metadata = {"assets": [{"id": 123, "name": "sqlite3.arm64.windows.dll", "size": len(self.content),
                                      "digest": f"sha256:{self.digest}"}]}

    def get_asset(self):
        return downloads.pinned_asset("simolus3/sqlite3.dart", "sqlite3-3.5.0", "sqlite3.arm64.windows.dll",
                                      self.digest, self.root, self.metadata)

    def test_rejects_upstream_digest_change_without_fetching(self):
        self.metadata["assets"][0]["digest"] = "sha256:" + "0" * 64
        with patch.object(downloads, "download_asset") as fetch, self.assertRaises(ValueError):
            self.get_asset()
        fetch.assert_not_called()

    def test_error_response_is_rejected_then_verified_retry_is_cached(self):
        attempts = []
        def fetch(repository, asset_id, path):
            attempts.append(asset_id)
            path.write_bytes(b"error page" if len(attempts) == 1 else self.content)
        with patch.object(downloads, "download_asset", side_effect=fetch), patch.object(downloads.time, "sleep"):
            result = self.get_asset()
        self.assertEqual(attempts, [123, 123])
        self.assertEqual(result.read_bytes(), self.content)
        with patch.object(downloads, "download_asset") as fetch:
            self.assertEqual(self.get_asset(), result)
            fetch.assert_not_called()

    def test_permanent_bad_response_never_populates_cache(self):
        with patch.object(downloads, "download_asset", side_effect=lambda repo, asset, path: path.write_bytes(b"error page")), \
                patch.object(downloads.time, "sleep"), self.assertRaises(RuntimeError):
            self.get_asset()
        self.assertFalse(any(path.name == "sqlite3.arm64.windows.dll" for path in self.root.rglob("*")))

    def test_unreviewed_producer_and_traversal_are_rejected(self):
        for repository, tag, name in (("other/sqlite3", "v1", "file"),
                                      ("simolus3/sqlite3.dart", "..", "file"),
                                      ("simolus3/sqlite3.dart", "v1", "../file")):
            with self.subTest(repository=repository, name=name), self.assertRaises(ValueError):
                downloads.pinned_asset(repository, tag, name, self.digest, self.root, self.metadata)

    def test_sqlite_staging_matches_the_unmodified_hook_hash_directory(self):
        asset = self.root / "downloaded.dll"
        asset.write_bytes(self.content)
        with patch.object(downloads, "sqlite_inputs", return_value=("sqlite3-3.5.0", {"sqlite3.arm64.windows.dll": self.digest})), \
                patch.object(downloads, "pinned_asset", return_value=asset):
            downloads.prepare_sqlite(self.root, "windows", "arm64", self.root / "cache")
        expected = self.root / ".dart_tool/hooks_runner/shared/sqlite3/build" / f"download-{self.digest[:8]}" / "sqlite3.dll"
        self.assertEqual(expected.read_bytes(), self.content)

    def test_libdovi_cache_wrapper_preserves_verified_archives_and_other_curl_calls(self):
        android = self.root / "android/app"
        android.mkdir(parents=True)
        declarations = ',\n'.join(f'"{abi}" to Pair("{triple}", "{self.digest}")' for abi, triple in
                                   (("arm64-v8a", "aarch64-linux-android"), ("armeabi-v7a", "armv7-linux-androideabi"),
                                    ("x86", "i686-linux-android"), ("x86_64", "x86_64-linux-android")))
        (android / "build.gradle.kts").write_text('val doviVersion = "2.3.1"\nval doviArtifacts = mapOf(\n' + declarations + '\n)')
        archive = self.root / "archive.tar.gz"
        archive.write_bytes(self.content)
        original_curl = self.root / "original-curl"
        original_curl.write_text('#!/bin/sh\nexit 7\n')
        original_curl.chmod(0o755)
        wrappers = self.root / "tools"
        with patch.object(downloads, "github_json", return_value={}), \
                patch.object(downloads, "pinned_asset", return_value=archive), \
                patch.object(downloads.shutil, "which", return_value=str(original_curl)), \
                patch.dict(downloads.os.environ, {"GITHUB_PATH": str(self.root / "github-path")}):
            downloads.prepare_dovi(self.root, self.root / "cache", wrappers)
        output = self.root / "staged.tar.gz"
        subprocess.run([str(wrappers / "curl"), "-sfL", "https://github.com/edde746/libdovi-builds/releases/download/v2.3.1/libdovi-aarch64-linux-android.tar.gz", "-o", str(output)], check=True)
        self.assertEqual(output.read_bytes(), self.content)
        self.assertEqual(subprocess.run([str(wrappers / "curl"), "--version"]).returncode, 7)
        archive.write_bytes(b"changed")
        self.assertNotEqual(subprocess.run([str(wrappers / "curl"), "-sfL", "https://github.com/edde746/libdovi-builds/releases/download/v2.3.1/libdovi-aarch64-linux-android.tar.gz", "-o", str(output)], capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
