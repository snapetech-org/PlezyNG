"""Keep release-tag and repository checks effective across publisher changes."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/update-packages.yml"


class UpdatePackagesWorkflowTest(unittest.TestCase):
    def run_guard(self, text: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workflow = root / ".github/workflows/update-packages.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text(text)
            scripts = root / "scripts/checks"
            scripts.mkdir(parents=True)
            for name in ("check_update_packages_workflow.py", "workflow_yaml.py"):
                shutil.copyfile(ROOT / "scripts/checks" / name, scripts / name)
            return subprocess.run(
                [sys.executable, str(scripts / "check_update_packages_workflow.py")],
                capture_output=True, text=True,
            )

    def test_current_publisher_passes(self) -> None:
        result = self.run_guard(WORKFLOW.read_text())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_legacy_appcast_writer_cannot_be_restored(self) -> None:
        result = self.run_guard(WORKFLOW.read_text() + "\n  update-appcast-branch:\n    runs-on: ubuntu-24.04\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("branch publishing must stay retired", result.stderr)

    def test_homebrew_requires_notarized_payload_even_without_outer_dmg_ticket(self) -> None:
        workflow = WORKFLOW.read_text()
        result = self.run_guard(workflow.replace('xcrun stapler validate "$app"', 'true', 1))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('mounted app signature, stapled ticket', result.stderr)

    def test_homebrew_checkout_cannot_target_an_unrelated_tap(self) -> None:
        workflow = WORKFLOW.read_text()
        original = "repository: snapetech-org/homebrew-pleazyng"
        self.assertIn(original, workflow)
        result = self.run_guard(workflow.replace(original, "repository: other/unrelated-tap", 1))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dedicated Pleazyng tap", result.stderr)

    def test_homebrew_download_cannot_target_another_repository(self) -> None:
        workflow = WORKFLOW.read_text()
        original = 'gh release download "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY"'
        self.assertIn(original, workflow)
        result = self.run_guard(workflow.replace(original, 'gh release download "$RELEASE_TAG" --repo "other/repository"', 1))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Homebrew must download from this repository", result.stderr)

    def test_homebrew_commit_must_retain_resolved_tag(self) -> None:
        workflow = WORKFLOW.read_text()
        original = 'git commit -m "Update Pleazyng Cask to $RELEASE_TAG"'
        self.assertIn(original, workflow)
        result = self.run_guard(workflow.replace(original, 'git commit -m "Update Pleazyng Cask"', 1))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Homebrew commit text must include the resolved tag", result.stderr)


if __name__ == "__main__":
    unittest.main()
