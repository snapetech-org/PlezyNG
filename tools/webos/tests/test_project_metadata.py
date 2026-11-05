"""Prevent expensive webOS builds from packaging an obsolete app version."""

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_package


class ProjectMetadataTest(unittest.TestCase):
    def test_metadata_matches_semantic_version_without_build_number(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "webos/meta").mkdir(parents=True)
            (root / "pubspec.yaml").write_text("version: 3.0.0+159\n")
            meta = root / "webos/meta/appinfo.json"
            meta.write_text(json.dumps({"id": verify_package.APP_ID, "type": "native", "version": "3.0.0"}))
            with patch.object(verify_package, "ROOT", root):
                verify_package.verify_project_metadata()
                for change in ({"version": "2.24.1"}, {"id": "com.upstream.plezy"}, {"type": "web"}):
                    meta.write_text(json.dumps({"id": verify_package.APP_ID, "type": "native", "version": "3.0.0", **change}))
                    with self.subTest(change=change), self.assertRaises(ValueError):
                        verify_package.verify_project_metadata()


if __name__ == "__main__":
    unittest.main()
