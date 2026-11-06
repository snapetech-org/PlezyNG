#!/usr/bin/env python3
"""Prevent stale or unpublished native inputs from reaching a release."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import sync_native_revision as native


class NativeSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.producer = self.root / "producer"
        self.revision = "a" * 40
        self.lock = self.root / "mpv-build.lock.json"
        self.write_lock(native.REPO, self.revision)

    def write_lock(self, repo, commit):
        self.lock.write_text(json.dumps({"repo": repo, "commit": commit}))

    def run_sync(self, *, check, fail_group=None, advance=False):
        def invoke(*args, **kwargs):
            if args[:2] == ("git", "rev-parse"):
                return self.revision
            if args[:2] == ("git", "ls-remote"):
                return ("b" * 40 if advance else self.revision) + "\trefs/heads/main"
            if len(args) > 1 and args[1] == "scripts/keys.py":
                if args[-1] == fail_group:
                    raise subprocess.CalledProcessError(1, args)
                return "published"
            return "pins updated"
        with patch.object(native, "command", side_effect=invoke) as command:
            native.sync(self.root, self.producer, check=check)
        return command.call_args_list

    def test_current_pin_checks_all_groups_without_mutation(self):
        calls = self.run_sync(check=True)
        self.assertEqual([c.args[-1] for c in calls if "scripts/keys.py" in c.args],
                         list(native.GROUPS))
        self.assertFalse(any("scripts/set_native_revision.sh" in c.args for c in calls))

    def test_stale_or_wrong_fork_pin_fails_before_build(self):
        for repo, revision in ((native.REPO, "b" * 40), ("edde746/mpv-build", self.revision)):
            self.write_lock(repo, revision)
            with self.assertRaisesRegex(ValueError, "next release"):
                self.run_sync(check=True)

    def test_unpublished_group_never_invokes_pin_writer(self):
        before = self.lock.read_bytes()
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_sync(check=False, fail_group="windows")
        self.assertEqual(self.lock.read_bytes(), before)

    def test_advancing_producer_main_requires_retry_without_mutation(self):
        before = self.lock.read_bytes()
        with self.assertRaisesRegex(ValueError, "advanced"):
            self.run_sync(check=False, advance=True)
        self.assertEqual(self.lock.read_bytes(), before)

    def test_sync_uses_existing_atomic_receipt_writer(self):
        self.write_lock(native.REPO, "b" * 40)
        calls = self.run_sync(check=False)
        self.assertEqual(calls[-1].args,
                         ("bash", "scripts/set_native_revision.sh", self.revision,
                          "--repo", str(self.producer)))

    def test_release_workflow_and_driver_gate_native_freshness(self):
        workflow = (native.ROOT / ".github/workflows/build.yml").read_text()
        gate = workflow.split("  validate-trusted-ref:", 1)[1].split("\n  build-", 1)[0]
        self.assertIn("python3 scripts/sync_native_revision.py --check", gate)
        driver = (native.ROOT / "scripts/release_all_platforms.py").read_text()
        self.assertIn('["python3", "scripts/sync_native_revision.py", "--check"]', driver)


if __name__ == "__main__":
    unittest.main()
