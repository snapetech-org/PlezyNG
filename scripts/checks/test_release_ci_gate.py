#!/usr/bin/env python3
"""Regression coverage for the exact-commit release CI gate manifest."""

from __future__ import annotations

import json
import datetime as dt
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from verify_release_ci import _manifest_gate  # noqa: E402
from verify_tvos_runner_acquisition import RunnerAcquisitionError  # noqa: E402
from release_all_platforms import (  # noqa: E402
    HOSTED_TVOS_QUEUE_TIMEOUT_SECONDS,
    ReleaseError,
    apple_workflow_route,
    dispatch,
    ensure_candidate_build,
    ensure_ci,
    ensure_tag,
    failed_preflight_ci_run,
    hosted_tvos_workflow_drained,
    select_apple_runner_pool,
    timed_out_unassigned_hosted_tvos_job,
    trusted_preflight_ci_run,
    trusted_release_workflow_run,
    release_ci_source,
    run_has_successful_step,
    wait_for_run,
)


class AppleRunnerRoutingTests(unittest.TestCase):
    def test_automatic_route_uses_compatible_hosted_apple_first(self) -> None:
        self.assertEqual(select_apple_runner_pool("auto"), "hosted")

    def test_mobile_hosted_macos_private_route_is_split(self) -> None:
        self.assertEqual(apple_workflow_route("hosted", "private"), "split")
        self.assertEqual(apple_workflow_route("private", "private"), "private")
        self.assertEqual(apple_workflow_route("hosted", "hosted"), "hosted")

    @patch("release_all_platforms.wait_for_run")
    @patch("release_all_platforms.workflow_runs")
    @patch("release_all_platforms.command")
    def test_split_dispatch_keeps_mac_private_and_mobile_queue_watch_enabled(
        self, _command, workflow_runs, wait_for_run_mock,
    ) -> None:
        run = {
            "databaseId": 17,
            "event": "workflow_dispatch",
            "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        }
        workflow_runs.return_value = [run]
        wait_for_run_mock.return_value = {"databaseId": 17, "conclusion": "success"}

        dispatch(
            "snapetech-org/pleazyng", "build.yml", "main",
            {"execution_profile": "hybrid", "tvos_runner_pool": "split"},
            "split Apple route", watch_hosted_tvos=True,
        )

        wait_for_run_mock.assert_called_once_with(
            "snapetech-org/pleazyng", run, "split Apple route", private_apple=True,
            allow_failure=False, watch_hosted_tvos=True,
        )

    @patch("release_all_platforms.ensure_remote_main_sha")
    @patch("release_all_platforms.dispatch", return_value={
        "databaseId": 18, "status": "completed", "conclusion": "success",
        "jobs": [{"name": "Build Windows (arm64)", "status": "completed", "conclusion": "success"}],
    })
    @patch("release_all_platforms.active_run", return_value=None)
    @patch("release_all_platforms.matching_run", return_value=None)
    def test_candidate_dispatch_routes_mobile_hosted_and_mac_private(
        self, _matching_run, _active_run, dispatch_mock, _ensure_main,
    ) -> None:
        ensure_candidate_build(
            "3.0.34", "a" * 40, tvos_runner_pool="auto", macos_runner_pool="private",
        )

        fields = dispatch_mock.call_args.args[3]
        self.assertEqual(fields["tvos_runner_pool"], "split")
        self.assertTrue(dispatch_mock.call_args.kwargs["watch_hosted_tvos"])

    def test_hosted_tvos_queue_timeout_requires_ten_minutes_without_a_runner(self) -> None:
        now = dt.datetime(2026, 11, 12, 18, 0, tzinfo=dt.timezone.utc)
        job = {
            "id": 42,
            "name": "Build tvOS developer package (arm64)",
            "status": "queued",
            "labels": ["macos-26"],
            "runner_id": None,
            "runner_name": None,
            "steps": [],
            "created_at": (now - dt.timedelta(seconds=HOSTED_TVOS_QUEUE_TIMEOUT_SECONDS)).isoformat(),
        }
        self.assertEqual(timed_out_unassigned_hosted_tvos_job([job], now_utc=now), 42)

        too_young = {**job, "created_at": (now - dt.timedelta(seconds=599)).isoformat()}
        assigned = {**job, "runner_id": 7, "runner_name": "GitHub Actions 7"}
        started = {**job, "status": "in_progress"}
        stepped = {**job, "steps": [{"name": "Set up job"}]}
        for invalid in (too_young, assigned, started, stepped):
            with self.subTest(job=invalid):
                self.assertIsNone(timed_out_unassigned_hosted_tvos_job([invalid], now_utc=now))

    def test_hosted_tvos_fallback_waits_for_platforms_and_release_assembly(self) -> None:
        tvos = {
            "name": "Build tvOS developer package (arm64)", "status": "queued",
            "labels": ["macos-26"], "runner_id": None, "runner_name": None, "steps": [],
        }
        platform = {"name": "build-android", "status": "completed", "conclusion": "success"}
        assembly = {
            "name": "create-release", "status": "queued", "runner_id": None,
            "runner_name": None, "steps": [],
        }
        self.assertTrue(hosted_tvos_workflow_drained([tvos, platform, assembly]))
        self.assertFalse(hosted_tvos_workflow_drained([
            tvos, {**platform, "status": "in_progress", "conclusion": None}, assembly,
        ]))
        self.assertFalse(hosted_tvos_workflow_drained([
            tvos, platform, {**assembly, "status": "in_progress", "runner_id": 9,
                            "runner_name": "ubuntu-1", "steps": [{"name": "Create release"}]},
        ]))

    def test_hosted_tvos_fallback_is_limited_to_trusted_release_builds(self) -> None:
        run = {
            "event": "workflow_dispatch", "head_branch": "main",
            "head_repository": {"full_name": "snapetech-org/pleazyng"},
            "path": ".github/workflows/build.yml@refs/heads/main",
            "display_title": "action:build:pool:private:mode:release:version:3.0.0",
        }
        self.assertTrue(trusted_release_workflow_run(run, "snapetech-org/pleazyng"))
        self.assertFalse(trusted_release_workflow_run(
            {**run, "head_branch": "feature/untrusted"}, "snapetech-org/pleazyng"
        ))
        self.assertFalse(trusted_release_workflow_run(
            {**run, "display_title": "action:build:mode:android-validation"},
            "snapetech-org/pleazyng",
        ))

    @patch("release_all_platforms.time.sleep")
    @patch("release_all_platforms.time.monotonic", side_effect=[0.0, 0.0])
    @patch("release_all_platforms.command")
    @patch("release_all_platforms.gh_json")
    @patch("release_all_platforms.subprocess.Popen")
    def test_watch_cancels_drained_run_only_after_hosted_tvos_timeout(
        self, popen, gh_json, command, _monotonic, _sleep,
    ) -> None:
        watcher = Mock()
        watcher.poll.side_effect = [None, 0]
        watcher.wait.return_value = 1
        popen.return_value = watcher
        now = dt.datetime.now(dt.timezone.utc)
        jobs = [
            {"id": 42, "name": "Build tvOS developer package (arm64)", "status": "queued",
             "labels": ["macos-26"], "runner_id": None, "runner_name": None, "steps": [],
             "created_at": (now - dt.timedelta(seconds=HOSTED_TVOS_QUEUE_TIMEOUT_SECONDS)).isoformat()},
            {"name": "build-android", "status": "completed", "conclusion": "success"},
            {"name": "create-release", "status": "queued", "runner_id": None,
             "runner_name": None, "steps": []},
        ]
        gh_json.side_effect = [
            {"id": 7, "status": "in_progress", "event": "workflow_dispatch", "head_branch": "main",
             "head_repository": {"full_name": "snapetech-org/pleazyng"},
             "path": ".github/workflows/build.yml@refs/heads/main",
             "display_title": "action:release:pool:private:tag:v3.0.0"},
            {"jobs": jobs, "total_count": len(jobs)},
            {"id": 7, "status": "in_progress", "event": "workflow_dispatch", "head_branch": "main",
             "head_repository": {"full_name": "snapetech-org/pleazyng"},
             "path": ".github/workflows/build.yml@refs/heads/main",
             "display_title": "action:release:pool:private:tag:v3.0.0"},
            {"jobs": jobs, "total_count": len(jobs)},
            {"status": "completed", "conclusion": "cancelled"},
            {"databaseId": 7, "status": "completed", "conclusion": "cancelled", "jobs": []},
        ]

        result = wait_for_run(
            "snapetech-org/pleazyng",
            {"databaseId": 7, "url": "https://github.com/snapetech-org/pleazyng/actions/runs/7"},
            "test hosted tvOS fallback", private_apple=False, allow_failure=True,
            watch_hosted_tvos=True,
        )

        self.assertEqual(result["conclusion"], "cancelled")
        command.assert_called_once_with(["gh", "run", "cancel", "7", "--repo", "snapetech-org/pleazyng"])

    @patch("release_all_platforms.apple_queue.active_run_scoped_apple_runner")
    def test_explicit_route_override_skips_private_capacity_probe(self, private_busy) -> None:
        self.assertEqual(select_apple_runner_pool("hosted"), "hosted")
        private_busy.assert_not_called()


class PreflightCIFastFailTests(unittest.TestCase):
    def setUp(self) -> None:
        self.run = {
            "id": 7,
            "event": "workflow_dispatch",
            "head_branch": "main",
            "head_repository": {"full_name": "snapetech-org/pleazyng"},
            "path": ".github/workflows/ci.yml@refs/heads/main",
            "display_title": "action:ci:pool:private:macos:private",
        }

    def test_only_trusted_main_preflight_ci_is_fast_fail_cancellable(self) -> None:
        self.assertTrue(trusted_preflight_ci_run(self.run, "snapetech-org/pleazyng"))
        for changes in (
            {"event": "pull_request"},
            {"head_branch": "feature/untrusted"},
            {"head_repository": {"full_name": "other/repository"}},
            {"path": ".github/workflows/build.yml@refs/heads/main"},
            {"display_title": "action:release:pool:private:tag:v3.0.0"},
        ):
            with self.subTest(changes=changes):
                self.assertFalse(trusted_preflight_ci_run({**self.run, **changes}, "snapetech-org/pleazyng"))

    def test_requires_a_completed_failing_job(self) -> None:
        active = {"name": "Apple native reliability (macOS)", "status": "in_progress"}
        passed = {"name": "Code Analysis", "status": "completed", "conclusion": "success"}
        failed = {"name": "Unit Tests", "status": "completed", "conclusion": "failure"}
        self.assertFalse(failed_preflight_ci_run(self.run, [active, passed]))
        self.assertTrue(failed_preflight_ci_run(self.run, [active, passed, failed]))
        self.assertFalse(failed_preflight_ci_run(
            {**self.run, "path": ".github/workflows/build.yml"}, [failed]
        ))

    @patch("release_all_platforms.time.sleep")
    @patch("release_all_platforms.time.monotonic", return_value=0.0)
    @patch("release_all_platforms.command")
    @patch("release_all_platforms.gh_json")
    @patch("release_all_platforms.subprocess.Popen")
    def test_cancels_failed_preflight_while_private_apple_job_is_active(
        self, popen, gh_json, command, _monotonic, _sleep,
    ) -> None:
        apple_controller = Mock()
        apple_controller.poll.return_value = None
        apple_controller.wait.return_value = 1
        watcher = Mock()
        watcher.poll.side_effect = [None, 0]
        watcher.wait.return_value = 1
        popen.side_effect = [apple_controller, watcher]
        jobs = [
            {"name": "Unit Tests", "status": "completed", "conclusion": "failure"},
            {"name": "Apple native reliability (macOS)", "status": "in_progress", "conclusion": None},
        ]
        completed_cancelled = {"id": 7, "status": "completed", "conclusion": "cancelled"}
        gh_json.side_effect = [
            self.run | {"status": "in_progress"},
            {"jobs": jobs, "total_count": len(jobs)},
            self.run | {"status": "in_progress"},
            {"jobs": jobs, "total_count": len(jobs)},
            completed_cancelled,
            {"databaseId": 7, "status": "completed", "conclusion": "cancelled", "jobs": []},
        ]

        with tempfile.TemporaryDirectory() as evidence:
            with patch("release_all_platforms.APPLE_JIT_EVIDENCE_ROOT", Path(evidence)):
                result = wait_for_run(
                    "snapetech-org/pleazyng",
                    {"databaseId": 7},
                    "Pleazyng CI",
                    private_apple=True,
                    allow_failure=True,
                    cancel_failed_preflight=True,
                )

        self.assertEqual(result["conclusion"], "cancelled")
        command.assert_called_once_with(["gh", "run", "cancel", "7", "--repo", "snapetech-org/pleazyng"])
        apple_controller.wait.assert_called_once()

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
            "snapetech-org/pleazyng",
            "ci.yml",
            "main",
            {
                "action": "ci",
                "runner_pool": "private",
                "execution_profile": "hybrid",
                "build_linux_packages": "true",
                "apple_runner_pool": "hosted",
            },
            "Pleazyng CI",
            expected_title="action:ci:pool:private:macos:hosted",
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
            "snapetech-org/pleazyng",
            "ci.yml",
            "main",
            {
                "action": "ci",
                "runner_pool": "private",
                "execution_profile": "hybrid",
                "build_linux_packages": "true",
                "apple_runner_pool": "hosted",
            },
            "Pleazyng CI",
            expected_title="action:ci:pool:private:macos:hosted",
            expected_sha=commit_sha,
        )

    @patch("release_all_platforms.dispatch")
    @patch("release_all_platforms.matching_run", return_value=None)
    def test_release_ci_dispatch_can_use_hosted_when_private_capacity_is_busy(
        self, _matching_run, dispatch
    ) -> None:
        commit_sha = "e" * 40
        ensure_ci(commit_sha, apple_runner_pool="hosted")

        self.assertEqual(dispatch.call_args.args[3]["apple_runner_pool"], "hosted")

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
            run_has_successful_step("snapetech-org/pleazyng", run, "build-ios", "Build signed iOS App Store IPA")
        )
        self.assertFalse(
            run_has_successful_step("snapetech-org/pleazyng", run, "build-ios", "Attest signed iOS App Store IPA")
        )

    @patch("release_all_platforms.ensure_remote_main_sha")
    @patch("release_all_platforms.dispatch", return_value={
        "databaseId": 7, "status": "completed", "conclusion": "success",
        "jobs": [{"name": "Build Windows (arm64)", "status": "completed", "conclusion": "success"}],
    })
    @patch("release_all_platforms.active_run", return_value=None)
    @patch("release_all_platforms.matching_run", return_value=None)
    def test_dispatches_full_nonpublishing_release_mode_on_exact_main_sha(
        self, _matching_run, _active_run, dispatch, ensure_main
    ) -> None:
        commit_sha = "b" * 40
        ensure_candidate_build("3.0.0", commit_sha)

        ensure_main.assert_called_once_with(commit_sha, "dispatching the 3.0.0 release-mode candidate")
        dispatch.assert_called_once_with(
            "snapetech-org/pleazyng",
            "build.yml",
            "main",
            {
                "action": "build",
                "runner_pool": "private",
                "execution_profile": "hybrid",
                "mode": "release",
                "build_version": "3.0.0",
                "include_webos_build": "true",
                "include_webos_release": "true",
                "include_tizen_build": "true",
                "include_apple_store_build": "false",
                "tvos_runner_pool": "hosted",
                "subtitle_gpu_backend": "cpu",
                "prepare_homebrew_cask": "false",
            },
            "Pleazyng 3.0.0 all-platform release-mode candidate",
            expected_title="action:build:pool:private:mode:release:version:3.0.0",
            expected_sha=commit_sha,
            allow_failure=True,
            watch_hosted_tvos=True,
        )

    @patch("release_all_platforms.ensure_remote_main_sha")
    @patch("release_all_platforms.dispatch", return_value={
        "databaseId": 8, "status": "completed", "conclusion": "success",
        "jobs": [
            {"name": "Build Windows (arm64)", "status": "completed", "conclusion": "success"},
            {"name": "build-ios", "steps": [{"name": "Build signed iOS App Store IPA", "status": "completed", "conclusion": "success"}]},
            {"name": "Build tvOS developer package (arm64)", "steps": [{"name": "Build signed tvOS App Store IPA", "status": "completed", "conclusion": "success"}]},
        ],
    })
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
            "snapetech-org/pleazyng",
            "build.yml",
            "b" * 40,
            ref="main",
            expected_title="action:build:pool:private:mode:release:version:3.0.0",
        )

    @patch("release_all_platforms.verify_unacquired_hosted_tvos_run", side_effect=RunnerAcquisitionError("build step ran"))
    @patch("release_all_platforms.matching_run")
    def test_rejects_a_failed_candidate_for_the_exact_commit(self, matching_run, _verify) -> None:
        matching_run.return_value = {"databaseId": 124, "status": "completed", "conclusion": "failure"}

        with self.assertRaisesRegex(ReleaseError, "not a verified hosted tvOS runner-acquisition cancellation"):
            ensure_candidate_build("3.0.0", "b" * 40)

    @patch("release_all_platforms.verify_unacquired_hosted_tvos_run", return_value={"run_id": 124})
    @patch("release_all_platforms.ensure_remote_main_sha")
    @patch("release_all_platforms.dispatch", return_value={
        "databaseId": 125, "status": "completed", "conclusion": "success",
        "jobs": [{"name": "Build Windows (arm64)", "status": "completed", "conclusion": "success"}],
    })
    @patch("release_all_platforms.active_run", return_value=None)
    @patch("release_all_platforms.matching_run")
    def test_hosted_allocation_failure_dispatches_a_unique_private_candidate_retry(
        self, matching_run, _active, dispatch, _main, verify
    ) -> None:
        matching_run.side_effect = [
            {"databaseId": 124, "status": "completed", "conclusion": "failure"},
            None,
        ]

        result = ensure_candidate_build("3.0.0", "b" * 40)

        self.assertEqual(result["databaseId"], 125)
        verify.assert_called_once_with(124, "b" * 40, "3.0.0", action="build")
        fields = dispatch.call_args.args[3]
        self.assertEqual(fields["tvos_runner_pool"], "private")
        self.assertEqual(fields["reuse_repaired_run_id"], "124")
        self.assertEqual(fields["rebuild_tvos"], "true")
        self.assertEqual(
            dispatch.call_args.kwargs["expected_title"],
            "action:build:pool:private:mode:release:version:3.0.0:runner-retry-of:124",
        )

    @patch("release_all_platforms.run_has_successful_job", return_value=True)
    @patch("release_all_platforms.verify_unacquired_hosted_tvos_run", return_value={"run_id": 124})
    @patch("release_all_platforms.ensure_remote_main_sha")
    @patch("release_all_platforms.dispatch", return_value={
        "databaseId": 125, "status": "completed", "conclusion": "success",
        "jobs": [{"name": "Build Windows (arm64)", "status": "completed", "conclusion": "success"}],
    })
    @patch("release_all_platforms.active_run", return_value=None)
    @patch("release_all_platforms.matching_run")
    @patch("release_all_platforms.wait_for_run", return_value={
        "databaseId": 124, "status": "completed", "conclusion": "failure",
    })
    def test_active_candidate_that_finishes_with_runnerless_tvos_retries_privately(
        self, wait, matching_run, _active, dispatch, _ensure_main, verify, _arm64_job,
    ) -> None:
        matching_run.side_effect = [
            {"databaseId": 124, "status": "in_progress", "conclusion": None},
            None,
        ]

        result = ensure_candidate_build("3.0.0", "b" * 40)

        self.assertEqual(result["databaseId"], 125)
        wait.assert_called_once_with(
            "snapetech-org/pleazyng", {"databaseId": 124, "status": "in_progress", "conclusion": None},
            "Pleazyng 3.0.0 all-platform release-mode candidate", private_apple=False,
            allow_failure=True, watch_hosted_tvos=True,
        )
        verify.assert_called_once_with(124, "b" * 40, "3.0.0", action="build")
        self.assertEqual(dispatch.call_args.args[3]["tvos_runner_pool"], "private")
        self.assertEqual(dispatch.call_args.args[3]["reuse_repaired_run_id"], "124")
        self.assertFalse(dispatch.call_args.kwargs["watch_hosted_tvos"])


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

    def test_infrastructure_reuses_only_the_validated_tag_ci_source(self) -> None:
        main_commit = self.commit_file("scripts/prepare_native_downloads.py", "# verified downloads\n")
        self.assertEqual(release_ci_source(self.checkout, "v3.0.0", main_commit, self.tag_commit), self.tag_commit)
        self.assertEqual(release_ci_source(self.checkout, "v3.0.1", main_commit, None), main_commit)
        changed = self.commit_file("lib/main.dart", "void main() { print('changed'); }\n")
        with self.assertRaisesRegex(ReleaseError, "non-release source files"):
            release_ci_source(self.checkout, "v3.0.0", changed, self.tag_commit)

    def test_workflow_ci_uses_the_validated_immutable_tag(self) -> None:
        import yaml
        workflow = yaml.safe_load((ROOT / ".github/workflows/build.yml").read_text())
        steps = workflow["jobs"]["validate-trusted-ref"]["steps"]
        gate = next(step for step in steps if step.get("name") == "Require successful CI for this commit")
        self.assertEqual(gate["env"]["COMMIT_SHA"], "${{ steps.release-tag.outputs.commit }}")
        tag = next(i for i, step in enumerate(steps) if step.get("id") == "release-tag")
        self.assertLess(tag, steps.index(gate))

    def test_rejects_application_changes_without_moving_the_tag(self) -> None:
        self.commit_file("CHANGELOG.md", "## [Unreleased]\n\n- Release infrastructure update.\n")
        main_commit = self.commit_file("lib/main.dart", "void main() { print('changed'); }\n")

        with self.assertRaisesRegex(ReleaseError, "non-release source files: lib/main.dart"):
            ensure_tag(self.checkout, "3.0.0", main_commit)
        self.assertEqual(self.git("rev-parse", "refs/tags/v3.0.0^{commit}"), self.tag_commit)


if __name__ == "__main__":
    unittest.main()
