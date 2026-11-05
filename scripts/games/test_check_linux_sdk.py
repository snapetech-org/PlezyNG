"""Linux preflight failures must remain visible in build-agent receipts."""
import subprocess
import unittest
from unittest.mock import patch

import check_linux_sdk as sdk


class LinuxSdkTests(unittest.TestCase):
    @staticmethod
    def output(args, **kwargs):
        if args == ["cmake", "--version"]:
            return "cmake version 3.28.3\n"
        if args[:2] == ["git", "status"]:
            return ""
        return "1.24.2\n"

    def test_missing_encoder_fails_while_other_versions_are_recorded(self):
        def output(args, **kwargs):
            if args[-1] == "openh264enc":
                raise subprocess.CalledProcessError(1, args)
            return self.output(args, **kwargs)
        with patch.object(sdk.subprocess, "check_output", side_effect=output):
            report = sdk.inspect()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["errors"], ["GStreamer element openh264enc"])
        self.assertEqual(report["packages"]["gstreamer-app-1.0"], "1.24.2")
        self.assertFalse(report["applicationBuilt"])
        self.assertFalse(report["gpuQualified"])

    def test_missing_executable_and_old_cmake_do_not_produce_success(self):
        def output(args, **kwargs):
            if args[0] == "pkg-config":
                raise FileNotFoundError("pkg-config")
            if args == ["cmake", "--version"]:
                return "cmake version 3.18.0\n"
            return self.output(args, **kwargs)
        with patch.object(sdk.subprocess, "check_output", side_effect=output):
            report = sdk.inspect()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(len(report["errors"]), len(sdk.PACKAGES) + 1)
        self.assertIn("CMake >= 3.22", report["errors"])


if __name__ == "__main__":
    unittest.main()
