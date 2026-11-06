"""Publication bootstrap gates and supported public runner dispatch routes."""
import contextlib
import io
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_all_platforms as release


class PublicationReadinessTests(unittest.TestCase):
    def run_channels(self, settings):
        assets = [
            'pleazyng-android-play.aab', 'SHA256SUMS.txt',
            'pleazyng-amazon-firetv.apk', 'pleazyng-ios-appstore.ipa',
            'pleazyng-tvos-appstore.ipa', 'pleazyng-macos.dmg', 'appcast.xml',
        ]
        secrets = {'GOOGLE_PLAY_SERVICE_ACCOUNT_JSON', 'AMAZON_APPSTORE_CLIENT_ID',
                   'AMAZON_APPSTORE_CLIENT_SECRET', 'APPLE_API_KEY_ID',
                   'APPLE_API_ISSUER_ID', 'APPLE_API_PRIVATE_KEY'}
        calls = []

        def dispatch(workflow, title, fields, purpose, **kwargs):
            calls.append((workflow, title, fields))
            return {'databaseId': 1, 'url': 'https://example.test/run'}

        with contextlib.redirect_stdout(io.StringIO()), patch.object(release, 'release_metadata', return_value={'assets': [{'name': x} for x in assets]}), \
             patch.object(release, 'configured_repo_names', return_value=secrets), \
             patch.object(release, 'configured_repo_variables', return_value=settings), \
             patch.object(release, 'ensure_channel_run', side_effect=dispatch):
            result = release.publish_configured_channels('v3.0.1', '3.0.1', release_sha='a' * 40, include_webos_release=False)
        return calls, result

    def test_unbootstrapped_stores_skip_even_when_secrets_and_assets_exist(self):
        calls, (_, skipped, _) = self.run_channels({})
        self.assertFalse(any(x[0] == 'publish-app-stores.yml' for x in calls))
        self.assertTrue(any('GOOGLE_PLAY_BOOTSTRAP_COMPLETE' in x['reason'] for x in skipped))
        self.assertTrue(any('APPLE_STORE_UPLOAD_READY' in x['reason'] for x in skipped))

    def test_closed_beta_activation_uses_public_runner_and_configured_track(self):
        calls, _ = self.run_channels({
            'GOOGLE_PLAY_BOOTSTRAP_COMPLETE': 'true',
            'GOOGLE_PLAY_TRACK': 'alpha', 'GOOGLE_PLAY_RELEASE_STATUS': 'completed',
        })
        play = next(x for x in calls if x[2].get('channel') == 'google-play')
        self.assertEqual(play[2]['runner_pool'], 'public')
        self.assertEqual(play[2]['play_track'], 'alpha')
        self.assertEqual(play[2]['play_release_status'], 'completed')
        self.assertIn('pool:public:', play[1])

    def test_appcast_dispatch_matches_public_only_workflow_input(self):
        calls, _ = self.run_channels({})
        appcast = next(x for x in calls if x[0] == 'update-packages.yml')
        self.assertEqual(appcast[2]['runner_pool'], 'public')

    def test_production_and_unrecognized_settings_are_rejected(self):
        for settings in [{'GOOGLE_PLAY_TRACK': 'production'}, {'GOOGLE_PLAY_RELEASE_STATUS': 'inProgress'}]:
            with self.assertRaises(release.ReleaseError):
                release.play_publication_settings(settings)


if __name__ == '__main__':
    unittest.main()
