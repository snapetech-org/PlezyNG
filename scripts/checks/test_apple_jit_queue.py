#!/usr/bin/env python3
"""Exercise queue transitions without creating runners or workflow runs."""

import importlib.util
import json
import os
import plistlib
import shutil
import subprocess
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


def failed_release():
    return {"id": 42, "status": "in_progress", "event": "workflow_dispatch",
            "head_branch": "main", "head_repository": {"full_name": queue.REPOSITORY},
            "path": ".github/workflows/build.yml", "display_title": "action:release:pool:private:tag:v3.0.3"}


class AppleQueueTests(unittest.TestCase):
    def test_transient_inventory_failure_recovers_without_abandoning_the_run(self):
        failed = subprocess.CompletedProcess([], 1, '', 'gh: Server Error (HTTP 503)')
        success = subprocess.CompletedProcess([], 0, '{"jobs": []}', '')
        with patch.object(queue.subprocess, 'run', side_effect=[failed, success]) as read, \
                patch.object(queue.time, 'sleep') as sleep:
            self.assertEqual(queue.gh_json('api', 'repos/example/actions/jobs'), {'jobs': []})
        self.assertEqual(read.call_count, 2)
        sleep.assert_called_once_with(2)

    def test_inventory_outage_retries_are_bounded_and_auth_failures_are_immediate(self):
        for status, attempts in ((503, 4), (403, 1)):
            failed = subprocess.CompletedProcess([], 1, '', f'gh: Server Error (HTTP {status})')
            with self.subTest(status=status), \
                    patch.object(queue.subprocess, 'run', return_value=failed) as read, \
                    patch.object(queue.time, 'sleep') as sleep:
                with self.assertRaises(queue.QueueError):
                    queue.gh_json('api', 'repos/example/actions/jobs')
                self.assertEqual(read.call_count, attempts)
                self.assertEqual(sleep.call_count, attempts - 1)

    def test_skipped_apple_jobs_have_no_logs_to_fetch_or_retry(self):
        with tempfile.TemporaryDirectory() as scratch, patch.object(queue.subprocess, 'run') as fetch:
            queue.save_github_logs('42', [{**apple_job('completed'), 'conclusion': 'skipped'}], Path(scratch))
            fetch.assert_not_called()
            self.assertEqual(list(Path(scratch).iterdir()), [])

    def test_executed_apple_job_still_retains_its_log(self):
        with tempfile.TemporaryDirectory() as scratch, patch.object(queue.subprocess, 'run') as fetch:
            fetch.return_value.returncode = 0
            queue.save_github_logs('42', [apple_job('completed')], Path(scratch))
            fetch.assert_called_once()
            self.assertTrue((Path(scratch) / '123-github-job.log').exists())

    def test_failed_release_waits_for_active_apple_work_then_stops_new_launches(self):
        failure = {"id": 2, "name": "WebOS", "status": "completed", "conclusion": "failure"}
        active = apple_job("in_progress")
        queued = {**apple_job(), "id": 124}
        with (
            tempfile.TemporaryDirectory() as scratch,
            patch.object(queue, "get_run", side_effect=[failed_release(), failed_release()]),
            patch.object(queue, "get_jobs", side_effect=[
                [failure, active, queued], [failure, apple_job("completed"), queued]]),
            patch.object(queue, "launch_job") as launch,
            patch.object(queue, "save_github_logs") as logs,
            patch.object(queue.time, "sleep") as sleep,
        ):
            self.assertEqual(queue.run_queue("42", Path(scratch)), 0)
            launch.assert_not_called()
            self.assertEqual(sleep.call_count, 1)
            logs.assert_called_once()

    def test_recovery_mode_completes_apple_jobs_after_a_non_apple_failure(self):
        failure = {"id": 2, "name": "WebOS", "status": "completed", "conclusion": "failure"}
        with tempfile.TemporaryDirectory() as scratch, \
                patch.object(queue, "get_run", side_effect=[failed_release(), {"status": "completed"}]), \
                patch.object(queue, "get_jobs", side_effect=[[failure, apple_job()], [failure, apple_job("completed")]]), \
                patch.object(queue, "get_job", return_value=apple_job("completed")), \
                patch.object(queue, "active_run_scoped_apple_runner", return_value=False), \
                patch.object(queue, "launch_job", return_value=0) as launch, \
                patch.object(queue, "save_github_logs"):
            self.assertEqual(queue.run_queue("42", Path(scratch), continue_after_platform_failure=True), 0)
            launch.assert_called_once()

    def test_recovery_mode_still_stops_on_an_apple_failure(self):
        failed = {**apple_job("completed"), "conclusion": "failure"}
        with tempfile.TemporaryDirectory() as scratch, \
                patch.object(queue, "get_run", return_value=failed_release()), \
                patch.object(queue, "get_jobs", return_value=[failed, {**apple_job(), "id": 124}]), \
                patch.object(queue, "launch_job") as launch, patch.object(queue, "save_github_logs"):
            self.assertEqual(queue.run_queue("42", Path(scratch), continue_after_platform_failure=True), 0)
            launch.assert_not_called()

    def test_ci_failure_does_not_stop_collection_of_other_test_results(self):
        run = {**failed_release(), "path": ".github/workflows/ci.yml"}
        self.assertFalse(queue.is_failed_release_build(run, [{"conclusion": "failure"}]))

    def test_release_wait_cancels_drained_queue_once_without_terminating_active_processes(self):
        controller = Mock()
        controller.poll.return_value = 0
        controller.wait.return_value = 0
        watcher = Mock()
        watcher.poll.side_effect = [None, None, 0]
        watcher.wait.return_value = 1
        jobs = [apple_job(), {"name": "WebOS", "status": "completed", "conclusion": "failure"}]
        with (
            tempfile.TemporaryDirectory() as scratch,
            patch.object(release, "APPLE_JIT_EVIDENCE_ROOT", Path(scratch)),
            patch.object(release.subprocess, "Popen", side_effect=[controller, watcher]),
            patch.object(release, "gh_json", side_effect=[failed_release(), {"jobs": jobs, "total_count": 2}]),
            patch.object(release, "command") as command,
            patch.object(release.time, "sleep"),
        ):
            with self.assertRaises(release.ReleaseError):
                release.wait_for_run(release.PLEZY_REPO, {"databaseId": 42}, "Release")
        command.assert_called_once_with(["gh", "run", "cancel", "42", "--repo", release.PLEZY_REPO])
        watcher.terminate.assert_not_called()
        controller.terminate.assert_not_called()

    def test_cancellation_waits_for_public_jobs_and_queued_packages(self):
        failed = {"name": "WebOS", "status": "completed", "conclusion": "failure"}
        pending_apple = apple_job()
        self.assertTrue(release.failed_build_has_drained(failed_release(), [failed, pending_apple]))
        for status in ("in_progress", "queued"):
            with self.subTest(status=status):
                self.assertFalse(release.failed_build_has_drained(
                    failed_release(), [failed, pending_apple, {"name": "package-windows", "status": status}]))

    def test_cancellation_does_not_touch_release_creation_side_effects(self):
        jobs = [apple_job(), {"name": "WebOS", "status": "completed", "conclusion": "failure"},
                {"name": "create-release", "status": "completed", "conclusion": "failure"}]
        self.assertFalse(release.failed_build_has_drained(failed_release(), jobs))

    def test_success_or_untrusted_run_never_triggers_drain_cancellation(self):
        self.assertFalse(release.failed_build_has_drained(failed_release(), [apple_job()]))
        for key, value in (("head_branch", "feature"), ("event", "pull_request"),
                           ("head_repository", {"full_name": "other/repository"})):
            with self.subTest(key=key):
                self.assertFalse(release.failed_build_has_drained(
                    {**failed_release(), key: value}, [{"status": "completed", "conclusion": "failure"}]))

    @unittest.skipUnless(shutil.which('jq'), 'launcher requires jq')
    def test_launcher_resolves_repository_identity_independently_of_product_brand(self):
        with tempfile.TemporaryDirectory(prefix='pleazyng-launcher-identity-') as temporary:
            root = Path(temporary)
            gh = root / 'gh'
            run = {'status': 'completed', 'run_attempt': 1, 'event': 'workflow_dispatch',
                   'head_branch': 'main', 'head_repository': {'full_name': 'snapetech-org/pleazyng'}}
            gh.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                          'args=sys.argv[1:]\n'
                          'if args[:2]==["repo","view"]:\n'
                          ' assert "GH_REPO" not in os.environ\n'
                          ' print("snapetech-org/pleazyng")\n'
                          'elif args==["api","repos/snapetech-org/pleazyng/actions/runs/42"]:\n'
                          f' print({json.dumps(json.dumps(run))})\n'
                          'else:\n raise SystemExit("Unexpected GitHub request: "+repr(args))\n')
            gh.chmod(0o755)
            result = subprocess.run(['bash', str(ROOT / 'scripts/launch_apple_jit_runner.sh'), '42', '123'],
                                    env={**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                                         'GH_REPO': 'unrelated/repository'},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('Run 42 is completed; refusing to add a runner.', result.stderr)
            self.assertNotIn('Unexpected GitHub request', result.stderr)

    def run_sequence(self, job_lists, launches, *, capacity=None):
        with tempfile.TemporaryDirectory(prefix="pleazyng-apple-queue-test-") as scratch:
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
        self.scratch = tempfile.TemporaryDirectory(prefix="pleazyng-derived-data-test-")
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

    def test_busy_or_unobservable_consumers_prevent_main_from_cleaning(self):
        owned = self.fixture("Runner-owned")
        runner = Path("/Users/gha-jit-macos/Library/Caches/gha-jit-macos/runs/42-123-attempt1/runner")
        failures = [
            (None, SystemExit),
            (subprocess.CalledProcessError(1, "ps"), subprocess.CalledProcessError),
            (subprocess.TimeoutExpired("ps", 5), subprocess.TimeoutExpired),
        ]
        for query_error, expected_error in failures:
            with self.subTest(query_error=query_error):
                elapsed = [0]
                def advance(seconds):
                    elapsed[0] += seconds
                with (
                    patch.object(sys, "argv", ["cleanup", "42", "1", str(runner), "success"]),
                    patch.object(Path, "is_dir", return_value=True),
                    patch.object(cleanup.time, "monotonic", side_effect=lambda: elapsed[0]),
                    patch.object(cleanup.time, "sleep", side_effect=advance),
                    patch.object(cleanup.subprocess, "check_output",
                                 return_value="/another/job/xcodebuild\n", side_effect=query_error),
                    patch.object(cleanup, "clean") as clean,
                ):
                    with self.assertRaises(expected_error):
                        cleanup.main()
                    clean.assert_not_called()
                self.assertEqual((owned / "Build/product").read_text(), "product")
                self.assertEqual((owned / "Logs/build.log").read_text(), "diagnostic")
                self.assertFalse((self.runner / "_diag/derived-data").exists())

    def test_main_cleans_and_retains_logs_after_transient_consumer_exits(self):
        owned = self.fixture("Runner-owned")
        runner = Path("/Users/gha-jit-macos/Library/Caches/gha-jit-macos/runs/42-123-attempt1/runner")
        clean = cleanup.clean
        is_dir = Path.is_dir
        elapsed = [0]
        def advance(seconds):
            elapsed[0] += seconds
        def clean_fixture(derived, runner_root, run_id, attempt, conclusion):
            return clean(self.derived, self.runner, run_id, attempt, conclusion)
        with (
            patch.object(sys, "argv", ["cleanup", "42", "1", str(runner), "success"]),
            patch.object(Path, "is_dir", autospec=True,
                         side_effect=lambda path: path == runner / "_diag" or is_dir(path)),
            patch.object(cleanup.time, "monotonic", side_effect=lambda: elapsed[0]),
            patch.object(cleanup.time, "sleep", side_effect=advance),
            patch.object(cleanup.subprocess, "check_output", side_effect=[
                "/other/Runner.Listener\n", "/usr/bin/python3\n",
            ]) as ps,
            patch.object(cleanup, "clean", side_effect=clean_fixture) as cleaned,
        ):
            cleanup.main()
        self.assertEqual(ps.call_count, 2)
        self.assertEqual(elapsed[0], 1)
        cleaned.assert_called_once()
        self.assertFalse(owned.exists())
        self.assertEqual((self.runner / "_diag/derived-data/Runner-owned/Logs/build.log").read_text(),
                         "diagnostic")


class ConsumerIdleWaitTests(unittest.TestCase):
    def setUp(self):
        self.elapsed = 0
        clock = patch.object(cleanup.time, "monotonic", side_effect=lambda: self.elapsed)
        sleep = patch.object(cleanup.time, "sleep", side_effect=self.advance)
        clock.start()
        self.sleep = sleep.start()
        self.addCleanup(clock.stop)
        self.addCleanup(sleep.stop)

    def advance(self, seconds):
        self.elapsed += seconds

    def test_idle_host_returns_without_sleeping(self):
        with patch.object(cleanup.subprocess, "check_output", return_value="/usr/bin/python3\n") as ps:
            cleanup.wait_for_idle()
        self.sleep.assert_not_called()
        self.assertEqual(ps.call_args.kwargs["timeout"], 5)

    def test_waits_for_both_listener_and_build_to_exit(self):
        with patch.object(cleanup.subprocess, "check_output", side_effect=[
            "/one/job/Runner.Listener\n/another/job/xcodebuild\n",
            "/another/job/xcodebuild\n", "/usr/bin/python3\n",
        ]) as ps:
            cleanup.wait_for_idle()
        self.assertEqual(ps.call_count, 3)
        self.assertEqual(self.elapsed, 2)

    def test_persistent_consumer_stops_at_deadline(self):
        with patch.object(cleanup.subprocess, "check_output", return_value="/other/Runner.Listener\n") as ps:
            with self.assertRaisesRegex(SystemExit, "within 2s.*Runner.Listener.*keeping DerivedData"):
                cleanup.wait_for_idle(timeout=2)
        self.assertEqual(self.elapsed, 2)
        self.assertEqual([call.kwargs["timeout"] for call in ps.call_args_list], [2, 1])

    def test_process_query_time_counts_toward_deadline(self):
        def slow_query(*args, **kwargs):
            self.elapsed += 1.75
            return "/other/xcodebuild\n"
        with patch.object(cleanup.subprocess, "check_output", side_effect=slow_query) as ps:
            with self.assertRaisesRegex(SystemExit, "keeping DerivedData"):
                cleanup.wait_for_idle(timeout=2)
        self.assertEqual(self.elapsed, 2)
        self.sleep.assert_called_once_with(0.25)
        ps.assert_called_once()


if __name__ == "__main__":
    unittest.main()
