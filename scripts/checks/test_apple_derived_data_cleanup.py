#!/usr/bin/env python3
"""Keep renamed Apple workspaces clean without touching unrelated build data."""

import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "apple_derived_data_cleanup",
    Path(__file__).resolve().parents[1] / "cleanup_apple_jit_derived_data.py",
)
CLEANUP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLEANUP)


class DerivedDataCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runner = self.root / "runner"
        self.derived = self.root / "DerivedData"
        self.derived.mkdir()

    def candidate(self, repository="pleazyng"):
        candidate = self.derived / "Runner-owned"
        (candidate / "Build").mkdir(parents=True)
        (candidate / "Build/result.bin").write_bytes(b"build evidence")
        (candidate / "Logs").mkdir()
        (candidate / "Logs/test.log").write_bytes(b"test diagnostics")
        workspace = self.runner / "_work" / repository / repository / "tvos/Runner.xcworkspace"
        with (candidate / "info.plist").open("wb") as stream:
            plistlib.dump({"WorkspacePath": str(workspace)}, stream)
        return candidate

    def test_renamed_workspace_build_is_removed_and_diagnostics_are_preserved(self):
        candidate = self.candidate()
        CLEANUP.clean(self.derived, self.runner, "123", "1", "success")
        self.assertFalse(candidate.exists())
        retained = self.runner / "_diag/derived-data/Runner-owned"
        self.assertEqual((retained / "Logs/test.log").read_bytes(), b"test diagnostics")
        self.assertTrue((retained / "info.plist").is_file())
        self.assertFalse((retained / "Build").exists())

    def test_failed_build_products_remain_in_diagnostic_archive(self):
        candidate = self.candidate()
        CLEANUP.clean(self.derived, self.runner, "123", "1", "failure")
        self.assertFalse(candidate.exists())
        retained = self.runner / "_diag/derived-data/Runner-owned"
        self.assertEqual((retained / "Build/result.bin").read_bytes(), b"build evidence")

    def test_unrelated_repository_outputs_are_preserved(self):
        candidate = self.candidate("unrelated")
        self.assertEqual(CLEANUP.clean(self.derived, self.runner, "123", "1", "success"), [])
        self.assertEqual((candidate / "Build/result.bin").read_bytes(), b"build evidence")

    def test_historical_workspace_names_remain_recognized(self):
        for repository in ("PlezyNG", "plezyng"):
            workspace = self.runner / "_work" / repository / repository / "ios/Runner.xcworkspace"
            self.assertTrue(CLEANUP.owned_workspace(str(workspace), self.runner, "123", "1"))

    def test_traversal_and_other_run_workspaces_are_rejected(self):
        workspace = self.runner / "_work/pleazyng/pleazyng/../unrelated/ios/Runner.xcworkspace"
        self.assertFalse(CLEANUP.owned_workspace(str(workspace), self.runner, "123", "1"))
        self.assertFalse(CLEANUP.owned_workspace(
            "/Volumes/p/runs/p999-1-tvos/tvos/Runner.xcworkspace", self.runner, "123", "1",
        ))


if __name__ == "__main__":
    unittest.main()
