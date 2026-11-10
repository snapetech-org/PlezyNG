import unittest
from pathlib import Path
from unittest.mock import call, patch

import build_macos_luajit_runtime as runtime


class VerifyArchitecturesTest(unittest.TestCase):
    def test_each_architecture_follows_the_binary(self):
        with patch.object(runtime, "run") as run:
            runtime.verify_architectures(Path("/tmp/lib luajit"), ["arm64", "x86_64"])
        self.assertEqual(run.call_args_list, [
            call("xcrun", "lipo", "/tmp/lib luajit", "-verify_arch", "arm64"),
            call("xcrun", "lipo", "/tmp/lib luajit", "-verify_arch", "x86_64"),
        ])


if __name__ == "__main__":
    unittest.main()
