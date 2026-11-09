#!/usr/bin/env python3
"""Keep historical attested Casks reproducible after the repository rename."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CaskPublisherTests(unittest.TestCase):
    def render(self, publisher=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checksums = root / "SHA256SUMS.txt"
            checksums.write_text("a" * 64 + "  pleazyng-macos.dmg\n")
            output = root / "cask.rb"
            command = [sys.executable, str(ROOT / "scripts/generate_homebrew_cask.py"),
                       "--version", "3.0.5", "--checksums", str(checksums), "--output", str(output)]
            if publisher is not None:
                identity = root / "publisher.txt"
                identity.write_text(publisher + "\n")
                command += ["--publisher-repository-file", str(identity)]
            result = subprocess.run(command, text=True, capture_output=True)
            return result, output.read_text() if output.exists() else None

    def test_new_releases_use_the_canonical_repository(self):
        result, text = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("github.com/snapetech-org/pleazyng/releases/", text)

    def test_historical_release_keeps_its_original_attested_urls(self):
        result, legacy = self.render("snapetech-org/PlezyNG")
        self.assertEqual(result.returncode, 0, result.stderr)
        _, canonical = self.render()
        self.assertEqual(legacy.replace("snapetech-org/PlezyNG", "snapetech-org/pleazyng"), canonical)

    def test_unrelated_publisher_cannot_change_the_download_origin(self):
        result, text = self.render("another/project")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(text)


if __name__ == "__main__":
    unittest.main()
