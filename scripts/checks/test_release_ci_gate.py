#!/usr/bin/env python3
"""Regression coverage for the exact-commit release CI gate manifest."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from verify_release_ci import _manifest_gate  # noqa: E402
from release_all_platforms import (  # noqa: E402
    ReleaseError,
    ensure_candidate_build,
    ensure_ci,
    ensure_tag,
    run_has_successful_step,
)


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
                "execution_profile": "hybrid",
                "build_linux_packages": "true",
            },
            "Pleazyng CI",
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
            "Pleazyng CI",
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
    def test_signed_apple_step_must_succeed_before_reusing_a_candidate(self) -> None:
        run = {
            "jobs": [
                {
                    "name": "build-ios",
                    "steps": [
                        {"name": "Build signed iOS App Store IPA", "status": "completed", "conclusion": "success"},
                        {"name": "Attest signed iOS App Store IPA", "status": "completed", "conclusion": "skipped"},
                    ],
                }
            ]
        }

        self.assertTrue(
            run_has_successful_step("snapetech-org/PlezyNG", run, "build-ios", "Build signed iOS App Store IPA")
        )
        self.assertFalse(
            run_has_successful_step("snapetech-org/PlezyNG", run, "build-ios", "Attest signed iOS App Store IPA")
        )

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
                "execution_profile": "hybrid",
                "mode": "release",
                "build_version": "3.0.0",
                "include_webos_build": "true",
                "include_webos_release": "false",
                "include_tizen_build": "true",
                "include_apple_store_build": "false",
                "subtitle_gpu_backend": "cpu",
                "prepare_homebrew_cask": "false",
            },
            "Pleazyng 3.0.0 all-platform release-mode candidate",
            expected_title="action:build:pool:private:mode:release:version:3.0.0",
            expected_sha=commit_sha,
        )

    @patch("release_all_platforms.ensure_remote_main_sha")
    @patch("release_all_platforms.dispatch")
    @patch("release_all_platforms.active_run", return_value=None)
    @patch("release_all_platforms.matching_run", return_value=None)
    def test_signed_apple_candidate_is_explicit_without_changing_runner_title(
        self, _matching_run, _active_run, dispatch, _ensure_main
    ) -> None:
        ensure_candidate_build("3.0.0", "e" * 40, include_apple_store_build=True)

        fields = dispatch.call_args.args[3]
        self.assertEqual(fields["include_apple_store_build"], "true")
        self.assertEqual(
            dispatch.call_args.kwargs["expected_title"],
            "action:build:pool:private:mode:release:version:3.0.0",
        )

    @patch("release_all_platforms.run_has_successful_job", return_value=True)
    @patch("release_all_platforms.matching_run")
    def test_reuses_only_a_successful_exact_version_candidate(
        self, matching_run, _arm64_job
    ) -> None:
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


class ImmutableReleaseTagTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="pleazyng-immutable-tag-")
        self.root = Path(self.tempdir.name)
        self.remote = self.root / "remote.git"
        self.checkout = self.root / "checkout"
        self.git_config = {
            "GIT_AUTHOR_NAME": "Release test",
            "GIT_AUTHOR_EMAIL": "release-test@example.invalid",
            "GIT_COMMITTER_NAME": "Release test",
            "GIT_COMMITTER_EMAIL": "release-test@example.invalid",
        }
        subprocess.run(["git", "init", "--bare", str(self.remote)], check=True, capture_output=True)
        subprocess.run(["git", "clone", str(self.remote), str(self.checkout)], check=True, capture_output=True)
        self.git("checkout", "-b", "main")
        self.checkout.joinpath("lib").mkdir()
        self.checkout.joinpath("lib/main.dart").write_text("void main() {}\n", encoding="utf-8")
        self.git("add", "lib/main.dart")
        self.git("commit", "-m", "initial source")
        self.git("tag", "-a", "v3.0.0", "-m", "Pleazyng 3.0.0")
        self.git("push", "-u", "origin", "main", "--tags")
        self.tag_commit = self.git("rev-parse", "refs/tags/v3.0.0^{commit}")

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def git(self, *args: str) -> str:
        result = subprocess.run(
            ["git", *args],
            cwd=self.checkout,
            env={**os.environ, **getattr(self, "git_config", {})},
            check=True,
            text=True,
            capture_output=True,
        )
        return result.stdout.strip()

    def commit_file(self, relative_path: str, contents: str) -> str:
        path = self.checkout / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        self.git("add", relative_path)
        self.git("commit", "-m", f"update {relative_path}")
        return self.git("rev-parse", "HEAD")

    def test_reuses_immutable_tag_after_allowlisted_release_changes(self) -> None:
        self.commit_file("CHANGELOG.md", "## [Unreleased]\n\n- Release infrastructure update.\n")
        main_commit = self.commit_file(".github/workflows/build.yml", "name: Pleazyng Release\n")

        self.assertEqual(ensure_tag(self.checkout, "3.0.0", main_commit), "v3.0.0")
        self.assertEqual(self.git("rev-parse", "refs/tags/v3.0.0^{commit}"), self.tag_commit)

    def test_rejects_application_changes_without_moving_the_tag(self) -> None:
        self.commit_file("CHANGELOG.md", "## [Unreleased]\n\n- Release infrastructure update.\n")
        main_commit = self.commit_file("lib/main.dart", "void main() { print('changed'); }\n")

        with self.assertRaisesRegex(ReleaseError, "non-release source files: lib/main.dart"):
            ensure_tag(self.checkout, "3.0.0", main_commit)
        self.assertEqual(self.git("rev-parse", "refs/tags/v3.0.0^{commit}"), self.tag_commit)


if __name__ == "__main__":
    unittest.main()
