import subprocess
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch
import zipfile

import check_android_package as package


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def archive(self, suffix=".apk", *, receiver=True, runtime=True, extra=None):
        path = self.root / ("app" + suffix)
        prefix = "lib/arm64-v8a/" if suffix == ".apk" else "base/lib/arm64-v8a/"
        with zipfile.ZipFile(path, "w") as output:
            output.writestr(prefix + "libflutter.so", b"engine")
            if receiver:
                output.writestr(prefix + "libplezy_steam.so", b"receiver")
            if runtime:
                output.writestr(prefix + "libc++_shared.so", b"runtime")
            if extra:
                output.writestr(extra, b"extra")
        return path

    def check(self, path, **kwargs):
        return package.check_package(path, {"arm64-v8a"}, Path("readelf"), Path("zipalign"), **kwargs)

    @patch.object(package, "inspect_elf")
    @patch.object(package.subprocess, "check_output", return_value="(NEEDED) Shared library: [libc++_shared.so]")
    @patch.object(package.subprocess, "run")
    def test_apk_checks_actual_extracted_receiver_and_alignment(self, run, readelf, inspect):
        report = self.check(self.archive())
        self.assertEqual(report["artifacts"][0]["bytes"], 8)
        self.assertGreater(report["artifacts"][0]["jniExportsChecked"], 40)
        self.assertTrue(report["apkAlignmentChecked"])
        self.assertFalse(report["signatureVerified"])
        inspect.assert_called_once()
        self.assertIn("--dyn-syms", readelf.call_args.args[0])
        self.assertEqual(run.call_args.args[0][1:5], ["-c", "-P", "16", "4"])

    def test_missing_receiver_and_wrong_abi_fail(self):
        with self.assertRaisesRegex(ValueError, "Receiver entries differ"):
            self.check(self.archive(receiver=False))
        with self.assertRaisesRegex(ValueError, "Receiver entries differ"):
            self.check(self.archive(extra="lib/x86/libplezy_steam.so"))

    def test_disabled_rejects_accidentally_shipped_receiver(self):
        with self.assertRaisesRegex(ValueError, "Receiver entries differ"):
            self.check(self.archive(), disabled=True)

    @patch.object(package.subprocess, "run")
    def test_disabled_still_checks_engine_abis_and_zip_alignment(self, run):
        report = self.check(self.archive(receiver=False), disabled=True)
        self.assertFalse(report["embeddedEnabled"])
        run.assert_called_once()

    @patch.object(package, "inspect_elf")
    @patch.object(package.subprocess, "check_output", return_value="(NEEDED) Shared library: [libc++_shared.so]")
    def test_missing_cpp_runtime_fails(self, *_):
        with self.assertRaisesRegex(ValueError, "Missing packaged runtime"):
            self.check(self.archive(runtime=False))

    @patch.object(package, "inspect_elf", side_effect=ValueError("missing JNI"))
    @patch.object(package.subprocess, "check_output", return_value="ELF")
    def test_stripped_jni_contract_failure_is_fatal(self, *_):
        with self.assertRaisesRegex(ValueError, "missing JNI"):
            self.check(self.archive())

    @patch.object(package, "inspect_elf")
    @patch.object(package.subprocess, "check_output", return_value="ELF")
    @patch.object(package.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "zipalign"))
    def test_bad_zip_alignment_is_fatal(self, *_):
        with self.assertRaises(subprocess.CalledProcessError):
            self.check(self.archive())

    @patch.object(package, "inspect_elf")
    @patch.object(package.subprocess, "check_output", return_value="ELF")
    @patch.object(package.subprocess, "run")
    def test_bundle_does_not_claim_generated_apk_alignment(self, run, *_):
        report = self.check(self.archive(".aab"))
        self.assertFalse(report["apkAlignmentChecked"])
        self.assertFalse(report["bundleGeneratedApksChecked"])
        run.assert_not_called()

    def test_duplicate_entries_fail(self):
        with self.assertWarns(UserWarning):
            path = self.archive(extra="lib/arm64-v8a/libplezy_steam.so")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.check(path)


if __name__ == "__main__":
    unittest.main()
