import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import urllib.error

import check_capability_manifest as check


class PublishedReleaseMetadataTest(unittest.TestCase):
    def setUp(self):
        check.ERRORS.clear()
        self.release = json.loads((check.ROOT / 'docs/maintainers/capability-manifest.json').read_text())['release']
        # Absence fixtures describe the historical observation, independently
        # of whichever release is currently published in the repository ledger.
        self.metadata = json.loads((check.ROOT / 'docs/maintainers/releases/v3.0.0.json').read_text())
        self.release.update(version='3.0.0', tag='v3.0.0', publicationStatus='unavailable',
                            publicLatestAvailable=False, sourceCommit=self.metadata['target_commitish'],
                            publishedAt=self.metadata['published_at'], missingPublicPlatforms=['webos'],
                            evidence='docs/maintainers/releases/v3.0.0.json',
                            availabilityCheckedOn='2026-11-06',
                            availabilityEvidence='docs/maintainers/releases/availability-2026-11-06.json')
        self.release.pop('targetCommitish', None)

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

    def test_live_documented_absence_needs_successful_list_and_missing_tag(self):
        with patch.object(check, '_release_json', side_effect=[
            (404, None), (200, [{'draft': True, 'prerelease': False}]), (404, None),
        ]):
            check.check_live_release(self.release, 'snapetech-org/PlezyNG', 'test-token')
        self.assertEqual(check.ERRORS, [])

    def test_live_published_release_still_requires_matching_metadata(self):
        self.release.update(publicLatestAvailable=True, publicationStatus='published')
        with patch.object(check, '_release_json', return_value=(200, self.metadata)):
            check.check_live_release(self.release, 'snapetech-org/PlezyNG', 'test-token')
        self.assertEqual(check.ERRORS, [])
        self.metadata['tag_name'] = 'v0.0.1'
        with patch.object(check, '_release_json', return_value=(200, self.metadata)):
            check.check_live_release(self.release, 'snapetech-org/PlezyNG', 'test-token')
        self.assertTrue(check.ERRORS)

    def test_latest_reappearance_invalidates_documented_absence(self):
        with patch.object(check, '_release_json', return_value=(200, self.metadata)):
            check.check_live_release(self.release, 'snapetech-org/PlezyNG', 'test-token')
        self.assertTrue(any('availability ledger' in error for error in check.ERRORS))

    def test_latest_404_does_not_hide_an_inaccessible_release_list(self):
        with patch.object(check, '_release_json', side_effect=[(404, None), (404, None)]):
            with self.assertRaisesRegex(ValueError, 'successful release list'):
                check.check_live_release(self.release, 'snapetech-org/PlezyNG', 'test-token')

    def test_missing_latest_does_not_allow_reappearing_tag_or_stable_list(self):
        for listed, tag in [([], (200, self.metadata)),
                            ([{'draft': False, 'prerelease': False}], (404, None))]:
            with self.subTest(listed=listed, tag_status=tag[0]):
                check.ERRORS.clear()
                with patch.object(check, '_release_json', side_effect=[(404, None), (200, listed), tag]):
                    check.check_live_release(self.release, 'snapetech-org/PlezyNG', 'test-token')
                self.assertTrue(check.ERRORS)

    def test_authentication_and_server_errors_are_not_absence(self):
        for status in (401, 403, 500):
            with self.subTest(status=status):
                error = urllib.error.HTTPError('https://api.github.com/test', status, 'failure', None, None)
                with patch.object(check.urllib.request, 'urlopen', side_effect=error):
                    with self.assertRaisesRegex(ValueError, f'HTTP {status}'):
                        check.check_live_release(self.release, 'snapetech-org/PlezyNG', 'test-token')

    def test_missing_authentication_does_not_make_requests(self):
        with patch.object(check, '_release_json') as request:
            with self.assertRaisesRegex(ValueError, 'GH_TOKEN'):
                check.check_live_release(self.release, 'snapetech-org/PlezyNG', '')
            request.assert_not_called()


if __name__ == '__main__':
    unittest.main()
