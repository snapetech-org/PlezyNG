#!/usr/bin/env python3
"""Exercise the real package resolver with GitHub release metadata fixtures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseMetadataTests(unittest.TestCase):
    def check_release(self, **changes):
        metadata = dict(tagName='v3.0.20', isDraft=False, isPrerelease=False, publishedAt='2026-11-09T00:00:00Z')
        metadata.update(changes)
        source = (ROOT / '.github/workflows/update-packages.yml').read_text()
        source = source.split('      - name: Resolve published release tag\n', 1)[1]
        source = source.split('        run: |\n', 1)[1].split('          VERSION=', 1)[0]
        script = textwrap.dedent(source)
        with tempfile.TemporaryDirectory(prefix='pleazyng-package-release-test-') as temporary:
            fake_gh = Path(temporary) / 'gh'
            fake_gh.write_text('#!/usr/bin/env python3\nimport os\nprint(os.environ["TEST_RELEASE_JSON"])\n')
            fake_gh.chmod(0o700)
            env = {**os.environ, 'PATH': temporary + os.pathsep + os.environ['PATH'],
                   'GITHUB_EVENT_NAME': 'workflow_dispatch', 'INPUT_TAG': 'v3.0.20',
                   'GITHUB_REPOSITORY': 'snapetech-org/pleazyng', 'TEST_RELEASE_JSON': json.dumps(metadata)}
            return subprocess.run(['bash', '-c', script], env=env, text=True, capture_output=True)

    def test_published_stable_release_is_accepted(self):
        self.assertEqual(self.check_release().returncode, 0)

    def test_stable_looking_tag_marked_prerelease_is_rejected(self):
        result = self.check_release(isPrerelease=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('pre-release', result.stderr)

    def test_missing_prerelease_metadata_fails_closed(self):
        self.assertNotEqual(self.check_release(isPrerelease=None).returncode, 0)

    def test_draft_is_rejected(self):
        self.assertNotEqual(self.check_release(isDraft=True).returncode, 0)

    def test_unpublished_is_rejected(self):
        self.assertNotEqual(self.check_release(publishedAt=None).returncode, 0)

    def test_tag_mismatch_is_rejected(self):
        self.assertNotEqual(self.check_release(tagName='v3.0.19').returncode, 0)


if __name__ == '__main__':
    unittest.main()
