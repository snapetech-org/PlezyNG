#!/usr/bin/env python3
"""Check safe installation and the shared Android cache contract."""

import importlib.util
import contextlib
import io
import re
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from workflow_yaml import job_block


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("prepare_gradle_repositories", ROOT / "scripts/prepare_gradle_repositories.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
spec = importlib.util.spec_from_file_location("run_android_build", ROOT / "scripts/run_android_build.py")
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)


class GradleRepositoryTests(unittest.TestCase):
    def test_ci_watcher_policy_preserves_other_properties_and_is_idempotent(self):
        with tempfile.TemporaryDirectory(prefix="pleazyng-gradle-watcher-") as scratch:
            home = Path(scratch)
            target = home / "gradle.properties"
            original = "# Preserve local configuration\norg.gradle.jvmargs=-Xmx3G\ncustom.property=unchanged\n"
            target.write_text(original + "org.gradle.vfs.watch: true\n")
            policy.configure_ci_watching(home)
            self.assertEqual(target.read_text(), original + "org.gradle.vfs.watch=false\n")
            policy.configure_ci_watching(home)
            self.assertEqual(target.read_text(), original + "org.gradle.vfs.watch=false\n")
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(home.glob(".pleazyng-properties-*")), [])

    def test_ci_watcher_policy_refuses_linked_properties(self):
        with tempfile.TemporaryDirectory(prefix="pleazyng-gradle-watcher-") as scratch:
            home = Path(scratch)
            outside = home / "preserved"
            outside.write_text("unchanged")
            (home / "gradle.properties").symlink_to(outside)
            with self.assertRaises(RuntimeError):
                policy.configure_ci_watching(home)
            self.assertEqual(outside.read_text(), "unchanged")

    def test_installs_policy_without_changing_other_init_scripts(self):
        with tempfile.TemporaryDirectory(prefix="pleazyng-gradle-policy-") as scratch:
            home = Path(scratch)
            (home / "init.d").mkdir()
            other = home / "init.d/unrelated.gradle"
            other.write_text("unchanged")
            target = policy.install(home)
            self.assertEqual(target.read_bytes(), policy.POLICY.read_bytes())
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            target.write_text("older policy")
            policy.install(home)
            self.assertEqual(target.read_bytes(), policy.POLICY.read_bytes())
            self.assertEqual(other.read_text(), "unchanged")
            self.assertEqual(list((home / "init.d").glob(".pleazyng-mirror-*")), [])

    def test_refuses_symlinked_policy_file(self):
        with tempfile.TemporaryDirectory(prefix="pleazyng-gradle-policy-") as scratch:
            home = Path(scratch)
            (home / "init.d").mkdir()
            outside = home / "preserved"
            outside.write_text("unchanged")
            (home / "init.d" / policy.POLICY.name).symlink_to(outside)
            with self.assertRaises(RuntimeError):
                policy.install(home)
            self.assertEqual(outside.read_text(), "unchanged")

    def test_refuses_symlinked_init_directory(self):
        with tempfile.TemporaryDirectory(prefix="pleazyng-gradle-policy-") as scratch:
            home = Path(scratch)
            outside = home / "other"
            outside.mkdir()
            (home / "init.d").symlink_to(outside, target_is_directory=True)
            with self.assertRaises(RuntimeError):
                policy.install(home)
            self.assertEqual(list(outside.iterdir()), [])

    def test_android_ci_and_release_share_cache_keys_and_bootstrap_policy(self):
        ci = job_block((ROOT / ".github/workflows/ci.yml").read_text(), "android-test")
        release = job_block((ROOT / ".github/workflows/build.yml").read_text(), "build-android")

        def field(block, step, name):
            text = block.split(f"- name: {step}\n", 1)[1]
            text = re.split(r"\n      - ", text, maxsplit=1)[0]
            return re.search(rf"^\s+{re.escape(name)}: (.+)$", text, re.MULTILINE).group(1)

        for step, name in (("Setup Flutter", "cache-key"),
                           ("Cache Pub dependencies", "key"), ("Cache Gradle", "key")):
            with self.subTest(step=step):
                self.assertEqual(field(ci, step, name), field(release, step, name))
        for block in (ci, release):
            self.assertIn("run: python3 scripts/prepare_gradle_repositories.py", block)

    def test_android_builds_are_observed_without_changing_release_variants(self):
        release = job_block((ROOT / ".github/workflows/build.yml").read_text(), "build-android")
        self.assertEqual(release.count("scripts/run_android_build.py flutter --verbose build "), 3)
        for flag in ("--split-per-abi", "--dart-define=SUPPORTER_MODE=iap", "--dart-define=AMAZON_STORE=true"):
            self.assertIn(flag, release)


class ObservedAndroidBuildTests(unittest.TestCase):
    def test_child_exit_status_is_retained_with_periodic_diagnostics(self):
        with patch.object(observer, "diagnostics") as diagnose, contextlib.redirect_stdout(io.StringIO()) as output:
            result = observer.run([sys.executable, "-c", "import time; time.sleep(.15); raise SystemExit(7)"], interval=.02, diagnose_every=.03)
        self.assertEqual(result, 7)
        self.assertIn("still running", output.getvalue())
        diagnose.assert_called()

    def test_unavailable_diagnostics_do_not_abort_the_build(self):
        with patch.object(observer.Path, "iterdir", return_value=[]), patch.object(observer.subprocess, "run", side_effect=FileNotFoundError), contextlib.redirect_stdout(io.StringIO()) as output:
            observer.diagnostics()
        self.assertIn("diagnostics unavailable", output.getvalue())

    @unittest.skipUnless(sys.platform == "linux", "Linux release process groups")
    def test_cancel_reaches_only_the_owned_build(self):
        with tempfile.TemporaryDirectory(prefix="pleazyng-android-observer-") as scratch:
            ready = Path(scratch) / "ready"
            unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
            child_code = "import pathlib,time; pathlib.Path(__import__('sys').argv[1]).write_text('ready'); time.sleep(30)"
            monitor = subprocess.Popen([sys.executable, str(ROOT / "scripts/run_android_build.py"), sys.executable, "-c", child_code, str(ready)])
            try:
                deadline = time.monotonic() + 10
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(ready.exists())
                monitor.send_signal(signal.SIGTERM)
                self.assertEqual(monitor.wait(timeout=10), 143)
                self.assertIsNone(unrelated.poll())
            finally:
                if monitor.poll() is None:
                    monitor.terminate()
                    monitor.wait(timeout=10)
                unrelated.terminate()
                unrelated.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
