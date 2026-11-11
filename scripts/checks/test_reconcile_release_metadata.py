import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import reconcile_release_metadata as reconcile


class MetadataPushTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.remote = self.root / "remote.git"
        self.repo = self.root / "source"
        self.other = self.root / "other"
        self.env = patch.dict(os.environ, {"GIT_AUTHOR_NAME": "QA", "GIT_AUTHOR_EMAIL": "qa@example.invalid",
                                          "GIT_COMMITTER_NAME": "QA", "GIT_COMMITTER_EMAIL": "qa@example.invalid"})
        self.env.start()
        self.addCleanup(self.env.stop)
        subprocess.run(["git", "init", "--bare", "--initial-branch=main", str(self.remote)], check=True, capture_output=True)
        subprocess.run(["git", "clone", str(self.remote), str(self.repo)], check=True, capture_output=True)
        metadata = self.repo / reconcile.METADATA_PATH
        metadata.parent.mkdir(parents=True)
        metadata.write_text("old\n")
        script = self.repo / "scripts/refresh_release_facts.py"
        script.parent.mkdir()
        script.write_text("from pathlib import Path\np=Path('linux/packaging/nix/release.json')\np.write_text('new\\n')\n")
        self.git(self.repo, "add", ".")
        self.git(self.repo, "commit", "-m", "seed")
        self.git(self.repo, "push", "origin", "main")
        subprocess.run(["git", "clone", str(self.remote), str(self.other)], check=True, capture_output=True)

    def git(self, repo, *args):
        return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout

    def test_metadata_only_push_and_noop(self):
        self.assertEqual(reconcile.reconcile(self.repo, self.root / "first"), "updated")
        self.git(self.other, "pull", "--ff-only")
        self.assertEqual(self.git(self.other, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").strip(),
                         reconcile.METADATA_PATH)
        self.assertEqual(reconcile.reconcile(self.repo, self.root / "second"), "unchanged")

    def test_concurrent_main_commit_is_preserved_and_regenerated(self):
        original = reconcile.git
        raced = False
        def concurrent(repo, *args, **kwargs):
            nonlocal raced
            if args[:1] == ("push",) and not raced:
                raced = True
                (self.other / "concurrent.txt").write_text("preserve me\n")
                self.git(self.other, "add", "concurrent.txt")
                self.git(self.other, "commit", "-m", "concurrent owner work")
                self.git(self.other, "push", "origin", "main")
            return original(repo, *args, **kwargs)
        with patch.object(reconcile, "git", side_effect=concurrent):
            self.assertEqual(reconcile.reconcile(self.repo, self.root / "race"), "updated")
        self.git(self.other, "pull", "--ff-only")
        self.assertEqual((self.other / "concurrent.txt").read_text(), "preserve me\n")
        self.assertEqual((self.other / reconcile.METADATA_PATH).read_text(), "new\n")
        self.assertTrue((self.root / "race/attempt-2.patch").exists())

    def test_unrelated_generated_change_is_never_staged_or_pushed(self):
        script = self.repo / "scripts/refresh_release_facts.py"
        script.write_text(script.read_text() + "Path('unrelated.txt').write_text('stop')\n")
        self.git(self.repo, "add", "scripts/refresh_release_facts.py")
        self.git(self.repo, "commit", "-m", "unexpected writer")
        self.git(self.repo, "push", "origin", "main")
        before = self.git(self.repo, "ls-remote", "origin", "refs/heads/main")
        scratch = self.root / "unsafe"
        with self.assertRaisesRegex(ValueError, "outside its ownership"):
            reconcile.reconcile(self.repo, scratch)
        self.assertEqual(before, self.git(self.repo, "ls-remote", "origin", "refs/heads/main"))
        self.assertTrue((scratch / "attempt-1/unrelated.txt").exists())
        # This is our temporary test repository; preserve the attempted files
        # until assertions finish, then unregister its task-owned worktree.
        self.git(self.repo, "worktree", "remove", "--force", str(scratch / "attempt-1"))

    def test_push_error_without_main_movement_is_not_retried(self):
        original = reconcile.git
        def rejected(repo, *args, **kwargs):
            if args[:1] == ("push",):
                return subprocess.CompletedProcess(args, 1, "", "denied")
            return original(repo, *args, **kwargs)
        with patch.object(reconcile, "git", side_effect=rejected), self.assertRaisesRegex(RuntimeError, "without concurrent"):
            reconcile.reconcile(self.repo, self.root / "denied")
        self.assertFalse((self.root / "denied/attempt-2").exists())


if __name__ == "__main__":
    unittest.main()
