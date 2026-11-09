import hashlib
from contextlib import redirect_stdout, redirect_stderr
import json
import io
import tarfile
from types import SimpleNamespace
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

    def test_legacy_release_without_github_digest_still_requires_the_full_independent_hash(self):
        self.metadata["assets"][0]["digest"] = None
        with patch.object(downloads, "download_asset", side_effect=lambda repo, asset, path: path.write_bytes(self.content)):
            self.assertEqual(self.get_asset().read_bytes(), self.content)

    def test_gradle_staging_is_consumed_by_the_unchanged_wrapper_url(self):
        wrapper = self.root / "android/gradle/wrapper"
        wrapper.mkdir(parents=True)
        (wrapper / "gradle-wrapper.properties").write_text("distributionUrl=https\\://services.gradle.org/distributions/gradle-9.6.1-all.zip\ndistributionSha256Sum=" + self.digest + "\n")
        archive = self.root / "gradle.zip"
        archive.write_bytes(self.content)
        home = self.root / "gradle-home"
        with patch.dict(downloads.os.environ, {"GRADLE_USER_HOME": str(home)}), patch.object(downloads, "pinned_asset", return_value=archive):
            downloads.prepare_gradle(self.root, self.root / "cache")
        staged = home / "wrapper/dists/gradle-9.6.1-all/4xnwe4ed5w7qqynisxnnvegss/gradle-9.6.1-all.zip"
        self.assertEqual(staged.read_bytes(), self.content)
        self.assertFalse(staged.with_suffix(".zip.ok").exists(), "Only the original Wrapper may acknowledge verification/extraction")

    def test_cocoapods_receives_only_the_original_verified_pdfium_zip(self):
        package = self.root / "pdfium-flutter"
        (package / "darwin").mkdir(parents=True)
        url = "https://github.com/espresso3389/pdfium-xcframework/releases/download/v1/PDFium.zip"
        (package / "darwin/pdfium_flutter.podspec").write_text(f'PDFIUM_URL = "{url}"\nPDFIUM_HASH = "{self.digest}"\n')
        (self.root / ".dart_tool").mkdir()
        (self.root / ".dart_tool/package_config.json").write_text(json.dumps({"packages": [{"name": "pdfium_flutter", "rootUri": package.as_uri()}]}))
        archive = self.root / "verified.zip"
        archive.write_bytes(self.content)
        curl = self.root / "original-curl"
        curl.write_text("#!/bin/sh\nexit 7\n")
        curl.chmod(0o755)
        with patch.dict(downloads.os.environ, {"RUNNER_TEMP": str(self.root), "GITHUB_PATH": str(self.root / "github-path")}), \
                patch.object(downloads, "pinned_asset", return_value=archive) as fetch, \
                patch.object(downloads.shutil, "which", return_value=str(curl)):
            downloads.prepare_apple_pdfium(self.root, self.root / "cache")
        self.assertEqual(fetch.call_args.args[:4], ("espresso3389/pdfium-xcframework", "v1", "PDFium.zip", self.digest))
        wrapper = self.root / "pleazyng-pdfium-curl/curl"
        args = [str(wrapper), "-L", "-o", "pdfium.zip", url]
        subprocess.run(args, cwd=self.root, check=True)
        self.assertEqual((self.root / "pdfium.zip").read_bytes(), self.content)
        self.assertEqual(subprocess.run([str(wrapper), "--version"], cwd=self.root).returncode, 7)
        archive.write_bytes(b"corrupt response")
        self.assertNotEqual(subprocess.run(args, cwd=self.root, capture_output=True).returncode, 0)

    def test_pdfium_stages_only_the_regular_pinned_library(self):
        package = self.root / "pdfium-package"
        (package / "hook").mkdir(parents=True)
        (package / "hook/build.dart").write_text("const _pdfiumRelease = 'chromium%2F7811';")
        (self.root / ".dart_tool").mkdir()
        (self.root / ".dart_tool/package_config.json").write_text(json.dumps({"packages": [{"name": "pdfium_dart", "rootUri": package.as_uri()}]}))
        archive = self.root / "pdfium.tgz"
        for unsafe in (False, True):
            with self.subTest(unsafe=unsafe):
                with tarfile.open(archive, "w:gz") as bundle:
                    entry = tarfile.TarInfo("lib/libpdfium.so")
                    if unsafe:
                        entry.type = tarfile.SYMTYPE
                        entry.linkname = "../../../outside"
                        bundle.addfile(entry)
                    else:
                        entry.size = len(self.content)
                        bundle.addfile(entry, io.BytesIO(self.content))
                with patch.object(downloads, "pinned_asset", return_value=archive):
                    if unsafe:
                        with self.assertRaises(ValueError):
                            downloads.prepare_pdfium(self.root, "linux", "x64", self.root / "cache")
                    else:
                        downloads.prepare_pdfium(self.root, "linux", "x64", self.root / "cache")
                        output = self.root / ".dart_tool/hooks_runner/shared/pdfium_dart/build/chromium_7811/linux-x64/libpdfium.so"
                        self.assertEqual(output.read_bytes(), self.content)

    def test_android_cmake_shares_verified_sources_and_keeps_binary_outputs_per_abi(self):
        cmake = self.root / "packages/plezy_torrent/src"
        cmake.mkdir(parents=True)
        (cmake / "CMakeLists.txt").write_text('FetchContent_Declare(libtorrent\n URL https://github.com/arvidn/libtorrent/releases/download/v2.0.11/source.tar.gz\n URL_HASH SHA256=' + self.digest + ')')
        def stage(url, digest, destination, cache):
            with tarfile.open(destination, "w:gz") as bundle:
                entry = tarfile.TarInfo("libtorrent-source/CMakeLists.txt")
                entry.size = len(self.content)
                bundle.addfile(entry, io.BytesIO(self.content))
        environment = self.root / "github-env"
        with patch.dict(downloads.os.environ, {"RUNNER_TEMP": str(self.root), "GITHUB_ENV": str(environment)}), patch.object(downloads, "prepare_github_url", side_effect=stage):
            downloads.prepare_cmake_downloads(self.root, "android", None, self.root / "cache")
        self.assertIn("PLEZYNG_CMAKE_SOURCE_LIBTORRENT=", environment.read_text())
        self.assertNotIn("FETCHCONTENT_BASE_DIR", environment.read_text())
        source = self.root / "pleazyng-cmake-sources/libtorrent-source/CMakeLists.txt"
        self.assertEqual(source.read_bytes(), self.content)

    def test_smb_keeps_the_original_hook_full_hash_cache_and_target_asset(self):
        package = self.root / "smb-package"
        (package / "hook").mkdir(parents=True)
        (package / "hook/build.dart").write_text("const _release = 'libsmb2-r9';\nconst hashes = {'libsmb2_windows-arm64.dll':\n '" + self.digest + "'};")
        (self.root / ".dart_tool").mkdir()
        (self.root / ".dart_tool/package_config.json").write_text(json.dumps({"packages": [{"name": "dart_smb2", "rootUri": package.as_uri()}]}))
        library = self.root / "verified.dll"
        library.write_bytes(self.content)
        with patch.object(downloads, "pinned_asset", return_value=library) as fetch:
            downloads.prepare_smb(self.root, "windows", "arm64", self.root / "cache")
        self.assertEqual(fetch.call_args.args[:4], ("ales-drnz/dart_smb2", "libsmb2-r9", "libsmb2_windows-arm64.dll", self.digest))
        output = self.root / ".dart_tool/hooks_runner/shared/dart_smb2/build" / self.digest / "libsmb2_windows-arm64.dll"
        self.assertEqual(output.read_bytes(), self.content)

    def test_apple_cmake_uses_the_existing_pod_dependency_download_cache(self):
        cmake = self.root / "packages/plezy_torrent/src"
        cmake.mkdir(parents=True)
        (cmake / "CMakeLists.txt").write_text('FetchContent_Declare(libtorrent\n URL https://github.com/arvidn/libtorrent/releases/download/v2.0.11/source.tar.gz\n URL_HASH SHA256=' + self.digest + ')')
        with patch.object(downloads, "prepare_github_url") as stage:
            downloads.prepare_cmake_downloads(self.root, "ios", None, self.root / "cache")
        output = stage.call_args.args[2]
        self.assertEqual(output, self.root / "build/p2p/dependencies/libtorrent-subbuild/libtorrent-populate-prefix/src/source.tar.gz")

    def test_python_bootstrap_preserves_existing_partial_and_complete_caches(self):
        toolcache = self.root / "toolcache"
        destination = toolcache / "Python/3.14.8/x64"
        destination.mkdir(parents=True)
        evidence = destination / "existing-build-evidence"
        evidence.write_text("preserve")
        original_read = Path.read_text
        def read(path, *args, **kwargs):
            return 'VERSION_ID="24.04"' if str(path) == "/etc/os-release" else original_read(path, *args, **kwargs)
        with patch.dict(downloads.os.environ, {"RUNNER_TOOL_CACHE": str(toolcache)}), \
                patch.object(downloads.os, "uname", return_value=SimpleNamespace(machine="x86_64")), \
                patch.object(Path, "read_text", read), patch.object(downloads, "pinned_asset") as fetch:
            with self.assertRaisesRegex(ValueError, "incomplete Python cache retained"):
                downloads.prepare_webos_python(self.root / "cache")
            self.assertEqual(evidence.read_text(), "preserve")
            destination.with_name("x64.complete").touch()
            with patch.object(downloads.subprocess, "check_output", return_value="Python 3.14.8\n"):
                downloads.prepare_webos_python(self.root / "cache")
            self.assertEqual(evidence.read_text(), "preserve")
            fetch.assert_not_called()

    def test_download_diagnostics_do_not_pollute_paths_consumed_by_cmake(self):
        output, diagnostics = io.StringIO(), io.StringIO()
        with redirect_stdout(output), redirect_stderr(diagnostics), patch.object(downloads, "download_asset", side_effect=lambda repo, asset, path: path.write_bytes(self.content)):
            self.get_asset()
        self.assertEqual(output.getvalue(), "")
        self.assertIn("Verified native download:", diagnostics.getvalue())

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
