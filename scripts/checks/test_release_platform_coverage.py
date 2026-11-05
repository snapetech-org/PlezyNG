from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_coverage import REQUIRED, missing_assets


class PlatformCoverageTest(unittest.TestCase):
    def setUp(self):
        self.names = {pattern.replace('*', 'org.plezy_3.0.0_arm')
                      for patterns in REQUIRED.values() for pattern in patterns}

    def test_complete_platform_matrix(self):
        self.assertEqual(missing_assets(self.names), [])

    def test_webos_cannot_be_replaced_with_a_candidate_build_receipt(self):
        self.names = {name for name in self.names if not name.endswith('.ipk')}
        self.names.add('webos-candidate-build-success.json')
        self.assertIn('webOS: *.ipk', missing_assets(self.names))

    def test_windows_arm64_is_required_independently_of_runner_profile(self):
        self.names.remove('plezy-windows-arm64-portable.zip')
        self.assertEqual(missing_assets(self.names), ['Windows ARM64: plezy-windows-arm64-portable.zip'])


if __name__ == '__main__':
    unittest.main()
