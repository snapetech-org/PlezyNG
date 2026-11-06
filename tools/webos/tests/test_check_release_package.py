"""Release integrity checks stay independent of device qualification."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_release_package as package


class ReleasePackageTests(unittest.TestCase):
    def exercise(self, **changes):
        report = {'packageSha256': 'b' * 64}
        record = {'sourceCommit': 'a' * 40, 'version': '3.0.1',
                  'packageSha256': report['packageSha256'], 'package': 'app.ipk',
                  'deviceQualification': 'not-completed'}
        record.update(changes)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'webos-app-provenance.json').write_text(json.dumps(record))
            with patch.object(package, 'expected_package_version', return_value='3.0.1'), \
                 patch.object(package, 'verify_ipk', return_value=report), \
                 patch.object(package, 'load_lock', return_value={}):
                return package.verify(root / 'app.ipk', 'a' * 40, '3.0.1')

    def test_unqualified_package_is_included_after_integrity_verification(self):
        self.assertEqual(self.exercise()['packageSha256'], 'b' * 64)

    def test_rejects_wrong_source(self):
        with self.assertRaisesRegex(ValueError, 'source differs'):
            self.exercise(sourceCommit='c' * 40)

    def test_rejects_wrong_version(self):
        with self.assertRaisesRegex(ValueError, 'version differs'):
            self.exercise(version='3.0.0')

    def test_rejects_changed_package(self):
        with self.assertRaisesRegex(ValueError, 'SHA-256'):
            self.exercise(packageSha256='c' * 64)

    def test_rejects_wrong_package_name(self):
        with self.assertRaisesRegex(ValueError, 'different package'):
            self.exercise(package='other.ipk')


if __name__ == '__main__':
    unittest.main()
