import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import release_all_platforms
from set_release_version import set_release_version


class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.pubspec = self.root / "pubspec.yaml"
        self.pubspec.write_text("name: plezy\nversion: 3.0.5+164\nflutter:\n  assets: []\n")
        self.appinfo = self.root / "webos/meta/appinfo.json"
        self.appinfo.parent.mkdir(parents=True)
        self.metadata = {"id": "org.snapetech.pleazyng", "type": "native", "version": "3.0.5",
                         "requiredACG": ["network.query"], "title": "Pleazyng"}
        self.appinfo.write_text(json.dumps(self.metadata))

    def test_updates_both_versions_preserving_other_settings(self):
        set_release_version(self.root, "3.0.7+166")
        self.assertEqual(self.pubspec.read_text(), "name: plezy\nversion: 3.0.7+166\nflutter:\n  assets: []\n")
        self.assertEqual(json.loads(self.appinfo.read_text()), {**self.metadata, "version": "3.0.7"})

    def test_can_repair_stale_webos_metadata_without_changing_flutter_version(self):
        self.pubspec.write_text("version: 3.0.7+166\n")
        set_release_version(self.root, "3.0.7+166")
        self.assertEqual(json.loads(self.appinfo.read_text())["version"], "3.0.7")

    def test_invalid_requested_version_changes_neither_file(self):
        before = (self.pubspec.read_bytes(), self.appinfo.read_bytes())
        for version in ("v3.0.7", "3.0.7", "3.0.7+invalid"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                set_release_version(self.root, version)
            self.assertEqual((self.pubspec.read_bytes(), self.appinfo.read_bytes()), before)

    def test_wrong_package_identity_changes_neither_file(self):
        self.appinfo.write_text(json.dumps({**self.metadata, "id": "org.other.app"}))
        before = (self.pubspec.read_bytes(), self.appinfo.read_bytes())
        with self.assertRaises(ValueError):
            set_release_version(self.root, "3.0.7+166")
        self.assertEqual((self.pubspec.read_bytes(), self.appinfo.read_bytes()), before)

    def test_symlinked_metadata_is_not_written(self):
        target = self.root / "shared.json"
        self.appinfo.rename(target)
        self.appinfo.symlink_to(target)
        before = self.pubspec.read_bytes()
        with self.assertRaises(ValueError):
            set_release_version(self.root, "3.0.7+166")
        self.assertEqual(self.pubspec.read_bytes(), before)

    def test_release_metadata_failure_precedes_auth_ci_and_tag_creation(self):
        arguments = SimpleNamespace(version="3.0.7", execution_profile="hybrid")
        with patch.object(release_all_platforms, "parse_args", return_value=arguments), \
                patch.object(release_all_platforms, "command", side_effect=[
                    SimpleNamespace(stdout="3.0.7+166\n"),
                    release_all_platforms.ReleaseError("metadata mismatch"),
                ]) as command:
            with self.assertRaisesRegex(release_all_platforms.ReleaseError, "metadata mismatch"):
                release_all_platforms.main()
        self.assertEqual(command.call_count, 2)
        self.assertEqual(command.call_args_list[1].args[0],
                         ["python3", "tools/webos/verify_package.py", "--project-metadata"])


if __name__ == "__main__":
    unittest.main()
