#!/usr/bin/env python3
"""Regression coverage for the exact-commit release CI gate manifest."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from verify_release_ci import _manifest_gate  # noqa: E402
from release_all_platforms import ensure_ci  # noqa: E402


class ReleaseCIGateManifestTests(unittest.TestCase):
    def test_reads_release_gate_from_capability_manifest(self) -> None:
        manifest = json.loads(
            (ROOT / "docs/maintainers/capability-manifest.json").read_text(encoding="utf-8")
        )
        release = manifest["release"]
        gate = _manifest_gate()

        self.assertEqual(gate["workflowId"], "ci.yml")
        self.assertEqual(gate["requiredJobs"], release["requiredCiJobs"])

    @patch("release_all_platforms.dispatch")
    @patch("release_all_platforms.matching_run", return_value=None)
    def test_release_ci_dispatch_includes_linux_package_smoke(self, _matching_run, dispatch) -> None:
        commit_sha = "a" * 40
        ensure_ci(commit_sha)

        dispatch.assert_called_once_with(
            "snapetech-org/PlezyNG",
            "ci.yml",
            "main",
            {"action": "ci", "runner_pool": "private", "build_linux_packages": "true"},
            "PlezyNG CI",
            expected_title="action:ci:pool:private",
            expected_sha=commit_sha,
        )


if __name__ == "__main__":
    unittest.main()
