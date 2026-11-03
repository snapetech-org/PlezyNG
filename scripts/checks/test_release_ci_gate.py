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
from release_all_platforms import ReleaseError, ensure_candidate_build, ensure_ci  # noqa: E402


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
            {
                "action": "ci",
                "runner_pool": "private",
                "execution_profile": "private",
                "build_linux_packages": "true",
            },
            "PlezyNG CI",
            expected_title="action:ci:pool:private",
            expected_sha=commit_sha,
        )

    @patch("release_all_platforms.dispatch")
    @patch("release_all_platforms.matching_run", return_value=None)
    def test_release_ci_dispatch_uses_hybrid_profile_when_requested(
        self, _matching_run, dispatch
    ) -> None:
        commit_sha = "c" * 40
        ensure_ci(commit_sha, execution_profile="hybrid")

        dispatch.assert_called_once_with(
            "snapetech-org/PlezyNG",
            "ci.yml",
            "main",
            {
                "action": "ci",
                "runner_pool": "private",
                "execution_profile": "hybrid",
                "build_linux_packages": "true",
            },
            "PlezyNG CI",
            expected_title="action:ci:pool:private",
            expected_sha=commit_sha,
        )

    @patch(
        "release_all_platforms.gh_json",
        return_value={
            "jobs": [
                {
                    "name": "Windows native reliability (arm64)",
                    "status": "completed",
                    "conclusion": "skipped",
                }
            ]
        },
    )
    @patch("release_all_platforms.dispatch")
    @patch(
        "release_all_platforms.matching_run",
        return_value={"databaseId": 42, "status": "completed", "conclusion": "success"},
    )
    def test_hybrid_ci_does_not_reuse_private_run_without_arm64(
        self, _matching_run, dispatch, _gh_json
    ) -> None:
        commit_sha = "d" * 40
        ensure_ci(commit_sha, execution_profile="hybrid")

        dispatch.assert_called_once()
        self.assertEqual(dispatch.call_args.args[3]["execution_profile"], "hybrid")


class ReleaseCandidateBuildGateTests(unittest.TestCase):
    @patch("release_all_platforms.ensure_remote_main_sha")
    @patch("release_all_platforms.dispatch")
    @patch("release_all_platforms.active_run", return_value=None)
    @patch("release_all_platforms.matching_run", return_value=None)
    def test_dispatches_full_nonpublishing_release_mode_on_exact_main_sha(
        self, _matching_run, _active_run, dispatch, ensure_main
    ) -> None:
        commit_sha = "b" * 40
        ensure_candidate_build("3.0.0", commit_sha)

        ensure_main.assert_called_once_with(commit_sha, "dispatching the 3.0.0 release-mode candidate")
        dispatch.assert_called_once_with(
            "snapetech-org/PlezyNG",
            "build.yml",
            "main",
            {
                "action": "build",
                "runner_pool": "private",
                "execution_profile": "private",
                "mode": "release",
                "build_version": "3.0.0",
                "include_webos_build": "true",
                "include_webos_release": "false",
                "include_tizen_build": "true",
                "subtitle_gpu_backend": "cpu",
                "prepare_homebrew_cask": "false",
            },
            "PlezyNG 3.0.0 all-platform release-mode candidate",
            expected_title="action:build:pool:private:mode:release:version:3.0.0",
            expected_sha=commit_sha,
        )

    @patch("release_all_platforms.matching_run")
    def test_reuses_only_a_successful_exact_version_candidate(self, matching_run) -> None:
        successful = {"databaseId": 123, "status": "completed", "conclusion": "success"}
        matching_run.return_value = successful

        self.assertIs(ensure_candidate_build("3.0.0", "b" * 40), successful)
        matching_run.assert_called_once_with(
            "snapetech-org/PlezyNG",
            "build.yml",
            "b" * 40,
            ref="main",
            expected_title="action:build:pool:private:mode:release:version:3.0.0",
        )

    @patch("release_all_platforms.matching_run")
    def test_rejects_a_failed_candidate_for_the_exact_commit(self, matching_run) -> None:
        matching_run.return_value = {"databaseId": 124, "status": "completed", "conclusion": "failure"}

        with self.assertRaisesRegex(ReleaseError, "refusing to tag an unvalidated commit"):
            ensure_candidate_build("3.0.0", "b" * 40)


if __name__ == "__main__":
    unittest.main()
