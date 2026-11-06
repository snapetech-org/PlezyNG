import copy
import json
from pathlib import Path
import unittest

import check_capability_manifest as check


class PublishedReleaseMetadataTest(unittest.TestCase):
    def setUp(self):
        check.ERRORS.clear()
        self.release = json.loads((check.ROOT / 'docs/maintainers/capability-manifest.json').read_text())['release']
        self.metadata = json.loads((check.ROOT / self.release['evidence']).read_text())

    def test_published_metadata_matches(self):
        check.check_published_release(self.release, self.metadata)
        self.assertEqual(check.ERRORS, [])

    def test_prior_draft_and_new_tag_are_detected(self):
        for field, value in [('draft', True), ('tag_name', 'v2.24.1'), ('target_commitish', 'different')]:
            with self.subTest(field=field):
                check.ERRORS.clear()
                metadata = copy.deepcopy(self.metadata)
                metadata[field] = value
                check.check_published_release(self.release, metadata)
                self.assertTrue(check.ERRORS)

    def test_adding_webos_requires_the_ledger_to_be_updated(self):
        self.metadata['assetNames'].append('pleazyng.ipk')
        check.check_published_release(self.release, self.metadata)
        self.assertTrue(any('webOS' in error for error in check.ERRORS))

    def test_unavailable_release_uses_current_observation_without_erasing_history(self):
        observation = json.loads((check.ROOT / self.release['availabilityEvidence']).read_text())
        check.check_release_availability(self.release, observation)
        check.check_published_release(self.release, self.metadata)
        self.assertEqual(check.ERRORS, [])

    def test_publication_or_tag_reappearance_invalidates_unavailable_status(self):
        original = json.loads((check.ROOT / self.release['availabilityEvidence']).read_text())
        for mutation in ('latest', 'tag', 'list', 'date', 'stable'):
            with self.subTest(mutation=mutation):
                check.ERRORS.clear()
                observation = copy.deepcopy(original)
                if mutation == 'latest':
                    observation['latestStatus'] = 200
                elif mutation == 'tag':
                    observation['tagStatus'] = 200
                elif mutation == 'list':
                    observation['listStatus'] = 403
                elif mutation == 'date':
                    observation['observedAt'] = 'old'
                else:
                    observation['listedReleases'].append({'draft': False, 'prerelease': False})
                check.check_release_availability(self.release, observation)
                self.assertTrue(check.ERRORS)


if __name__ == '__main__':
    unittest.main()
