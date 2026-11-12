#!/usr/bin/env python3
"""Regression tests for narrow hosted tvOS allocation recovery evidence."""

import sys
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from verify_tvos_runner_acquisition import (  # noqa: E402
    RunnerAcquisitionError,
    verify_unacquired_hosted_tvos_run,
)


class HostedTvosRunnerAcquisitionTests(unittest.TestCase):
    def setUp(self):
        self.run = {
            "id": 42,
            "event": "workflow_dispatch",
            "head_branch": "main",
            "head_repository": {"full_name": "snapetech-org/pleazyng"},
            "path": ".github/workflows/build.yml@refs/heads/main",
            "status": "completed",
            "conclusion": "failure",
            "head_sha": "a" * 40,
            "display_title": "action:release:pool:private:tag:v3.0.0",
            "run_attempt": 2,
        }
        self.jobs = {
            "total_count": 3,
            "jobs": [
                {"id": 51, "name": "Validate release request", "status": "completed", "conclusion": "success"},
                {"id": 52, "name": "Build tvOS developer package (arm64)",
                 "status": "completed", "conclusion": "cancelled", "labels": ["macos-26"],
                 "runner_id": 0, "runner_name": "", "steps": []},
                {"id": 53, "name": "create-release", "status": "completed", "conclusion": "skipped"},
            ],
        }

    def verify(self, **kwargs):
        with patch("verify_tvos_runner_acquisition.gh_api", side_effect=[self.run, self.jobs]):
            return verify_unacquired_hosted_tvos_run(
                42, "a" * 40, "3.0.0", action="release", **kwargs
            )

    def test_accepts_only_confirmed_no_runner_cancellation(self):
        proof = self.verify()
        self.assertEqual(proof["tvos_job_id"], 52)
        self.assertEqual(proof["runner_id"], 0)
        self.assertEqual(proof["steps"], 0)

    def test_rejects_an_assigned_runner(self):
        self.jobs["jobs"][1]["runner_id"] = 123
        self.jobs["jobs"][1]["runner_name"] = "macos-hosted-1"
        with self.assertRaisesRegex(RunnerAcquisitionError, "not proven canceled"):
            self.verify()

    def test_rejects_a_job_that_started_steps(self):
        self.jobs["jobs"][1]["steps"] = [{"name": "Set up job", "conclusion": "success"}]
        with self.assertRaisesRegex(RunnerAcquisitionError, "not proven canceled"):
            self.verify()

    def test_rejects_other_failed_jobs(self):
        self.jobs["jobs"][0]["conclusion"] = "failure"
        with self.assertRaisesRegex(RunnerAcquisitionError, "other incomplete or failed jobs"):
            self.verify()

    def test_rejects_an_incomplete_job_inventory(self):
        self.jobs["total_count"] = 4
        with self.assertRaisesRegex(RunnerAcquisitionError, "inventory is incomplete"):
            self.verify()

    def test_candidate_retry_requires_candidate_title(self):
        self.run["display_title"] = "action:build:pool:private:mode:release:version:3.0.0"
        with patch("verify_tvos_runner_acquisition.gh_api", side_effect=[self.run, self.jobs]):
            proof = verify_unacquired_hosted_tvos_run(
                42, "a" * 40, "3.0.0", action="build"
            )
        self.assertEqual(proof["action"], "build")


if __name__ == "__main__":
    unittest.main()
