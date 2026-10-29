"""Preparation safety tests. Mocks are not evidence of an Apple SDK build."""
from pathlib import Path
import json
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import prepare_apple_sdk as sdk


class AppleSdkPreparationTests(unittest.TestCase):
    def test_targets_preserve_deployment_minimums_and_simulator_identity(self):
        expected = {
            "macosx": "arm64-apple-macosx14.0",
            "iphoneos": "arm64-apple-ios15.5",
            "iphonesimulator": "arm64-apple-ios15.5-simulator",
            "appletvos": "arm64-apple-tvos15.0",
            "appletvsimulator": "arm64-apple-tvos15.0-simulator",
        }
        for name, triple in expected.items():
            self.assertEqual(sdk.target_triple(name, "arm64"), triple)
        self.assertEqual(sdk.target_triple("macosx", "x86_64"), "x86_64-apple-macosx14.0")
        for name in ("iphoneos", "appletvos"):
            with self.assertRaises(ValueError):
                sdk.target_triple(name, "x86_64")

    def test_invalid_runtime_fails_before_any_machine_change(self):
        for name, version in (("iphoneos", "26.0"), ("macosx", "26.0"), ("iphonesimulator", "latest")):
            with patch.object(sdk, "run") as run, patch.object(sdk, "output") as output:
                with self.assertRaises(ValueError):
                    sdk.prepare({}, name, version)
                run.assert_not_called()
                output.assert_not_called()

    def test_wrong_xcode_build_fails_before_component_install(self):
        with patch.object(sdk, "output", return_value="Xcode 26.0\nBuild version 17A123"), \
                patch.object(sdk, "run") as run:
            with self.assertRaisesRegex(ValueError, "does not match"):
                sdk.prepare({}, "macosx", None, "17B456")
            run.assert_not_called()

    def test_prepare_downloads_metal_and_only_requested_simulator_runtime(self):
        def output(args, env):
            if args[0] == "xcrun":
                raise subprocess.CalledProcessError(1, args)
            return "Xcode 26.0\nBuild version 17A123"
        with patch.object(sdk, "output", side_effect=output), \
                patch.object(sdk, "run") as run:
            sdk.prepare({}, "appletvsimulator", "26.0", "17A123")
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(commands, [
                ["xcodebuild", "-runFirstLaunch"],
                ["xcodebuild", "-downloadComponent", "metalToolchain"],
                ["xcodebuild", "-downloadPlatform", "tvOS", "-buildVersion", "26.0"],
            ])

    def test_bundled_metal_does_not_require_new_xcode_download_command(self):
        with patch.object(sdk, "output", return_value="Xcode 16.0\nBuild version 16A123"), \
                patch.object(sdk, "run") as run:
            sdk.prepare({}, "macosx", None)
            run.assert_called_once_with(["xcodebuild", "-runFirstLaunch"], {})

    def test_xcode_selection_is_process_local(self):
        with tempfile.TemporaryDirectory() as temporary:
            application = Path(temporary) / "Xcode.app"
            developer = application / "Contents/Developer"
            (developer / "usr/bin").mkdir(parents=True)
            (developer / "usr/bin/xcodebuild").touch()
            with patch.dict(sdk.os.environ, {"DEVELOPER_DIR": "/original"}, clear=True):
                self.assertEqual(sdk.environment(application)["DEVELOPER_DIR"], str(developer))
                self.assertEqual(sdk.os.environ["DEVELOPER_DIR"], "/original")
            with self.assertRaises(ValueError):
                sdk.environment(Path(temporary) / "CommandLineTools")

    def test_failed_probe_replaces_stale_success_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / "result.json"
            report.write_text('{"status":"passed","sourceProbesPassed":true}')
            args = ["prepare_apple_sdk.py", "probe", "--sdk", "macosx", "--report", str(report)]
            with patch.object(sdk.os.sys, "argv", args), \
                    patch.object(sdk.platform, "system", return_value="Darwin"), \
                    patch.object(sdk, "inspect", return_value={}), \
                    patch.object(sdk, "probe", side_effect=subprocess.CalledProcessError(1, ["clang++"])):
                with self.assertRaises(subprocess.CalledProcessError):
                    sdk.main()
            result = json.loads(report.read_text())
            self.assertEqual(result["status"], "failed")
            self.assertFalse(result["sourceProbesPassed"])
            self.assertFalse(result["flutterAdapterChecked"])
            self.assertEqual(list(report.parent.glob("*.pending")), [])

    def test_old_cmake_fails_inspection(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name in sdk.FRAMEWORKS:
                (directory / "System/Library/Frameworks" / f"{name}.framework").mkdir(parents=True)

            def output(args, env):
                if args == ["xcodebuild", "-version"]:
                    return "Xcode 26.0\nBuild version 17A123"
                if "--show-sdk-path" in args:
                    return str(directory)
                if "--version" in args:
                    return "cmake version 3.21.4"
                return "/usr/bin/" + args[-1]

            with patch.object(sdk, "output", side_effect=output), \
                    patch.object(sdk.shutil, "which", return_value="/usr/bin/cmake"):
                with self.assertRaisesRegex(ValueError, "CMake 3.22"):
                    sdk.inspect({}, "macosx", "arm64")


if __name__ == "__main__":
    unittest.main()
