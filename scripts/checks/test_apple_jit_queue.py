#!/usr/bin/env python3
"""Exercise queue transitions without creating runners or workflow runs."""

import importlib.util
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[2]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    with patch.object(sys, "path", [str(ROOT / "scripts"), *sys.path]):
        spec.loader.exec_module(module)
    return module


queue = load_script("launch_queued_apple_jit_jobs")
release = load_script("release_all_platforms")
cleanup = load_script("cleanup_apple_jit_derived_data")


def apple_job(status="queued"):
    return {
        "id": 123,
        "name": "Apple job",
        "status": status,
        "conclusion": "success" if status == "completed" else None,
        "labels": ["private-apple", "macOS", "ARM64", "gha-42-build-ios"],
    }


class AppleQueueTests(unittest.TestCase):
    def run_sequence(self, job_lists, launches, *, capacity=None):
        with tempfile.TemporaryDirectory(prefix="plezyng-apple-queue-test-") as scratch:
            with (
                patch.object(queue, "get_run", side_effect=[
                    {"status": "in_progress"}, {"status": "in_progress"},
                    {"status": "completed"},
                ]),
                patch.object(queue, "get_jobs", side_effect=job_lists),
                patch.object(queue, "active_run_scoped_apple_runner",
                             side_effect=capacity or [False, False]),
                patch.object(queue, "launch_job", side_effect=launches) as launch,
                patch.object(queue, "save_github_logs"),
                patch.object(queue.time, "sleep") as sleep,
            ):
                self.assertEqual(queue.run_queue("42", Path(scratch)), 0)
                return launch.call_count, sleep.call_count

    def test_discovers_platform_job_after_initial_validation(self):
        launches, sleeps = self.run_sequence(
            [[], [apple_job()], [apple_job("completed")], [apple_job("completed")]],
            [0],
        )
        self.assertEqual(launches, 1)
        self.assertEqual(sleeps, 1)

    def test_failed_launch_retries_queued_job_instead_of_waiting_forever(self):
        launches, sleeps = self.run_sequence(
            [[apple_job()], [apple_job()], [apple_job()],
             [apple_job("completed")], [apple_job("completed")]],
            [1, 0],
        )
        self.assertEqual(launches, 2)
        self.assertEqual(sleeps, 1)

    def test_busy_mac_slot_prevents_a_second_launch(self):
        launches, sleeps = self.run_sequence(
            [[apple_job()], [apple_job()], [apple_job("completed")],
             [apple_job("completed")]],
            [0],
            capacity=[True, False],
        )
        self.assertEqual(launches, 1)
        self.assertEqual(sleeps, 1)

    def test_release_starts_discovery_before_platform_jobs_exist(self):
        controller = Mock()
        controller.wait.return_value = 0
        watcher = Mock()
        watcher.poll.return_value = 0
        watcher.wait.return_value = 0
        completed = {"status": "completed", "conclusion": "success"}
        with (
            patch.object(release, "APPLE_JIT_EVIDENCE_ROOT", Path("/task/evidence")),
            patch.object(release.subprocess, "Popen", side_effect=[controller, watcher]) as popen,
            patch.object(release, "gh_json", return_value=completed) as api,
        ):
            self.assertEqual(
                release.wait_for_run(release.PLEZY_REPO, {"databaseId": 42}, "CI"),
                completed,
            )
        self.assertTrue(popen.call_args_list[0].args[0][1].endswith("launch_queued_apple_jit_jobs.py"))
        self.assertEqual(popen.call_args_list[1].args[0][:3], ["gh", "run", "watch"])
        api.assert_called_once()


class DerivedDataCleanupTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="plezyng-derived-data-test-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.derived = self.root / "DerivedData"
        self.runner = self.root / "runner"
        self.derived.mkdir()
        (self.runner / "_diag").mkdir(parents=True)

    def fixture(self, name, run_id="42"):
        path = self.derived / name
        (path / "Build").mkdir(parents=True)
        (path / "Build/product").write_text("product")
        (path / "Logs").mkdir()
        (path / "Logs/build.log").write_text("diagnostic")
        with (path / "info.plist").open("wb") as stream:
            plistlib.dump({"WorkspacePath": f"/Volumes/p/runs/p{run_id}-1-ios/ios/Runner.xcworkspace"}, stream)
        return path

    def test_success_clears_only_matching_output_and_preserves_logs(self):
        owned = self.fixture("Runner-owned")
        other = self.fixture("Runner-other", "41")
        cache = self.derived / "ModuleCache.noindex"
        cache.mkdir()
        cleanup.clean(self.derived, self.runner, "42", "1", "success")
        self.assertFalse(owned.exists())
        self.assertTrue(other.exists())
        self.assertTrue(cache.exists())
        self.assertEqual((self.runner / "_diag/derived-data/Runner-owned/Logs/build.log").read_text(), "diagnostic")

    def test_failed_job_retains_build_products_in_the_diagnostic_archive(self):
        owned = self.fixture("Runner-owned")
        cleanup.clean(self.derived, self.runner, "42", "1", "failure")
        self.assertFalse(owned.exists())
        self.assertEqual((self.runner / "_diag/derived-data/Runner-owned/Build/product").read_text(), "product")

    def test_shared_package_cache_prevents_deletion(self):
        owned = self.fixture("Runner-owned")
        (owned / "SourcePackages").mkdir()
        cleanup.clean(self.derived, self.runner, "42", "1", "success")
        self.assertTrue(owned.exists())

    def test_symlink_to_another_directory_is_preserved(self):
        other = self.fixture("Other-output")
        (self.derived / "Runner-link").symlink_to(other, target_is_directory=True)
        cleanup.clean(self.derived, self.runner, "42", "1", "success")
        self.assertTrue(other.exists())


if __name__ == "__main__":
    unittest.main()
