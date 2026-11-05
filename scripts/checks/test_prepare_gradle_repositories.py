#!/usr/bin/env python3
"""Check safe installation and the shared Android cache contract."""

import importlib.util
import re
import tempfile
import unittest
from pathlib import Path

from workflow_yaml import job_block


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("prepare_gradle_repositories", ROOT / "scripts/prepare_gradle_repositories.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class GradleRepositoryTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
