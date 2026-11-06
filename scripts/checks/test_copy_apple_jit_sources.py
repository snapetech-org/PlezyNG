#!/usr/bin/env python3
"""Verify exact tracked source staging without an Apple runner or NFS writes."""

import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("copy_sources", ROOT / "scripts/copy_apple_jit_sources.py")
copy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(copy)


class SourceCopyTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="pleazyng-source-copy-test-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.source = self.root / "original checkout"
        self.destination = self.root / "task scratch"
        self.source.mkdir()
        self.destination.mkdir()
        self.git("init", "--quiet")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        (self.source / ".gitignore").write_text(".cache/\nbuild/\n")
        (self.source / "tracked file.txt").write_bytes(b"exact source\x00bytes\n")
        (self.source / "script.sh").write_text("#!/bin/sh\nexit 0\n")
        (self.source / "script.sh").chmod(0o755)
        (self.source / "source-link").symlink_to("tracked file.txt")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "fixture")
        self.revision = self.git("rev-parse", "HEAD")

    def git(self, *args, root=None):
        return subprocess.check_output(["git", "-C", str(root or self.source), *args],
                                       text=True, stderr=subprocess.PIPE).strip()

    def stage(self):
        copy.copy_sources(self.source, self.destination, self.revision)

    def test_preserves_tracked_bytes_modes_links_and_git_queries_without_caches_or_credentials(self):
        for name in [".cache", "build"]:
            (self.source / name).mkdir()
            (self.source / name / "large-cache").write_text("must remain in the original checkout")
        (self.source / "untracked-note").write_text("not part of the source revision")
        self.git("config", "http.https://example.invalid/.extraheader", "fixture-header")
        self.stage()
        self.assertEqual(self.git("rev-parse", "HEAD", root=self.destination), self.revision)
        self.assertEqual(self.git("ls-files", root=self.destination), self.git("ls-files"))
        self.assertEqual((self.destination / "tracked file.txt").read_bytes(), b"exact source\x00bytes\n")
        self.assertTrue(os.access(self.destination / "script.sh", os.X_OK))
        self.assertEqual(os.readlink(self.destination / "source-link"), "tracked file.txt")
        for name in [".cache", "build", "untracked-note"]:
            self.assertFalse((self.destination / name).exists())
            self.assertTrue((self.source / name).exists())
        self.assertNotIn("fixture-header", (self.destination / ".git/config").read_text())
        self.assertEqual((self.destination / ".git/objects/info/alternates").read_text().strip(),
                         str(self.source / ".git/objects"))

    def test_rejects_modified_or_staged_tracked_sources_before_copying(self):
        for staged in [False, True]:
            with self.subTest(staged=staged):
                (self.source / "script.sh").write_text("changed source")
                if staged:
                    self.git("add", "script.sh")
                with self.assertRaisesRegex(ValueError, "modified tracked"):
                    self.stage()
                self.assertEqual(list(self.destination.iterdir()), [])

    def test_rejects_a_different_revision(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            copy.copy_sources(self.source, self.destination, "0" * 40)
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_preserves_nonempty_or_symlink_destination(self):
        marker = self.destination / "evidence"
        marker.write_text("retain")
        with self.assertRaisesRegex(ValueError, "empty directory"):
            self.stage()
        self.assertEqual(marker.read_text(), "retain")
        linked = self.root / "redirect"
        linked.symlink_to(self.destination, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "empty directory"):
            copy.copy_sources(self.source, linked, self.revision)
        self.assertEqual(marker.read_text(), "retain")

    def test_supports_shallow_actions_checkout(self):
        shallow = self.root / "shallow"
        subprocess.run(["git", "clone", "--quiet", "--depth=1", self.source.as_uri(), str(shallow)],
                       check=True)
        self.assertEqual(self.git("rev-parse", "--is-shallow-repository", root=shallow), "true")
        copy.copy_sources(shallow, self.destination, self.revision)
        self.assertEqual(self.git("rev-parse", "HEAD", root=self.destination), self.revision)
        self.assertEqual((self.destination / "tracked file.txt").read_bytes(), b"exact source\x00bytes\n")


if __name__ == "__main__":
    unittest.main()
