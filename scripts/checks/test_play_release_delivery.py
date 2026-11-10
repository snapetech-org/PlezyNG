#!/usr/bin/env python3
import datetime as dt
import base64
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('play_delivery', ROOT / 'scripts/stores/deliver_play_releases.py')
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)
import release_all_platforms as release_publisher


class DeliveryTests(unittest.TestCase):
    def release(self):
        names = set('''pleazyng-android-arm64-v8a.tar.gz pleazyng-android-armeabi-v7a.tar.gz
            pleazyng-android-x86_64.tar.gz pleazyng-amazon-firetv.apk pleazyng-amazon-firetv-provenance.json
            pleazyng-linux-x64.tar.gz pleazyng-linux-arm64.tar.gz pleazyng-windows-x64-portable.7z
            pleazyng-windows-arm64-portable.zip pleazyng-macos.dmg pleazyng-ios-unsigned.ipa
            pleazyng-tvos-unsigned.ipa pleazyng-tizen-arm-tester-handoff.zip
            org.snapetech.pleazyng_3.0.29_arm.ipk webos-SHA256SUMS.txt pleazyng-lg-webos-submission.zip'''.split())
        names.update({'pleazyng-android-play.aab', 'SHA256SUMS.txt'})
        return {'tag_name': 'v3.0.29', 'draft': False, 'prerelease': False,
                'assets': [{'name': name, 'size': 1} for name in names]}

    def test_only_complete_matching_fresh_stable_release(self):
        release = self.release()
        self.assertEqual(delivery.release_version(release, 'version: 3.0.29+188', 188), 188)
        for key in ('draft', 'prerelease'):
            with self.subTest(key=key):
                self.assertIsNone(delivery.release_version({**release, key: True}, 'version: 3.0.29+188', 188))
        self.assertIsNone(delivery.release_version(release, 'version: 3.0.7+166', 188))
        with self.assertRaisesRegex(ValueError, 'immutable source'):
            delivery.release_version(release, 'version: 3.0.30+189', 188)

    def test_missing_any_platform_blocks_delivery(self):
        release = self.release()
        for asset in release['assets']:
            with self.subTest(asset=asset['name']):
                broken = {**release, 'assets': [item for item in release['assets'] if item != asset]}
                with self.assertRaisesRegex(ValueError, 'incomplete release coverage'):
                    delivery.release_version(broken, 'version: 3.0.29+188', 188)

    def test_delivery_is_idempotent_serial_and_retry_throttled_per_track(self):
        now = dt.datetime.now(dt.timezone.utc)
        run = {'display_title': 'action:publish-app-stores:pool:public:tag:v3.0.29:channel:google-play:track:internal:status:completed',
               'head_branch': 'main', 'event': 'workflow_dispatch', 'status': 'completed',
               'conclusion': 'success', 'updated_at': now.isoformat()}
        self.assertEqual(delivery.delivery_state([run], 'v3.0.29', now), 'delivered')
        self.assertEqual(delivery.delivery_state([{**run, 'display_title': run['display_title'].replace('status:completed', 'status:draft')}], 'v3.0.29', now), 'dispatch')
        self.assertEqual(delivery.delivery_state([run], 'v3.0.29', now, 'alpha'), 'dispatch')
        self.assertEqual(delivery.delivery_state([{**run, 'status': 'in_progress', 'conclusion': None}], 'v3.0.29', now), 'pending')
        failed = {**run, 'conclusion': 'failure'}
        self.assertEqual(delivery.delivery_state([failed], 'v3.0.29', now), 'retry_cooldown')
        self.assertEqual(delivery.delivery_state([failed], 'v3.0.29', now + dt.timedelta(minutes=3)), 'dispatch')
        self.assertEqual(delivery.delivery_state([{**run, 'head_branch': 'untrusted'}], 'v3.0.29', now), 'dispatch')

    def test_track_and_bootstrap_settings(self):
        self.assertEqual(delivery.settings({}), ('internal', 188))
        for environment in ({'GOOGLE_PLAY_AUTO_TRACK': 'production'},
                            {'GOOGLE_PLAY_AUTO_TRACK': 'alpha'},
                            {'GOOGLE_PLAY_MIN_VERSION_CODE': '167'}):
            with self.assertRaises(ValueError):
                delivery.settings(environment)
        self.assertEqual(delivery.settings({'GOOGLE_PLAY_AUTO_TRACK': 'alpha', 'GOOGLE_PLAY_BOOTSTRAP_COMPLETE': 'true'}), ('alpha', 188))

    def test_incomplete_release_does_not_block_a_later_complete_release(self):
        incomplete = self.release()
        incomplete['assets'] = [asset for asset in incomplete['assets'] if asset['name'] != 'pleazyng-macos.dmg']
        complete = {**self.release(), 'tag_name': 'v3.0.30'}
        def api(path):
            if path.startswith('contents/'):
                version = '3.0.29+188' if 'v3.0.29' in path else '3.0.30+189'
                return {'content': base64.b64encode(f'version: {version}'.encode()).decode()}
            return {'status': 'ahead'}
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / 'delivery.json'
            with patch.object(sys, 'argv', ['delivery', '--dispatch', '--receipt', str(receipt)]), \
                 patch.dict(os.environ, {'GITHUB_REPOSITORY': delivery.REPOSITORY, 'GOOGLE_PLAY_AUTOMATIC_RELEASES': 'true', 'GOOGLE_PLAY_AUTO_TRACK': 'internal'}), \
                 patch.object(delivery, 'pages', side_effect=lambda path, key=None: [] if key else [incomplete, complete]), \
                 patch.object(delivery, 'api', side_effect=api), patch.object(delivery, 'gh', return_value='') as dispatch:
                with self.assertRaisesRegex(ValueError, 'other complete releases'):
                    delivery.main()
            self.assertEqual(dispatch.call_count, 1)
            self.assertIn('release_tag=v3.0.30', dispatch.call_args.args)
            result = json.loads(receipt.read_text())
            self.assertEqual(result['errors'][0]['tag'], 'v3.0.29')
            self.assertEqual(result['releases'][0]['state'], 'dispatched')


class AutomaticPostReleaseTests(unittest.TestCase):
    def test_token_created_release_dispatches_without_manual_channels_flag(self):
        with patch.object(release_publisher, 'configured_repo_variables', return_value={'GOOGLE_PLAY_AUTOMATIC_RELEASES': 'true'}), \
             patch.object(release_publisher, 'command') as dispatch:
            result = release_publisher.post_release_actions('v3.0.29', '3.0.29', release_sha='a' * 40,
                include_webos_release=True, publish_channels=False)
        commands = [call.args[0] for call in dispatch.call_args_list]
        play = [command for command in commands if 'deliver-google-play.yml' in command]
        self.assertEqual(len(play), 1)
        self.assertIn('release_tag=v3.0.29', play[0])
        self.assertEqual(result['google_play_automation'][0]['state'], 'dispatched')
        self.assertFalse(result['channel_failures'])

    def test_failed_automatic_delivery_preserves_core_followup_results(self):
        def command(args):
            if 'deliver-google-play.yml' in args:
                raise release_publisher.ReleaseError('synthetic delivery outage')
        with patch.object(release_publisher, 'configured_repo_variables', return_value={'GOOGLE_PLAY_AUTOMATIC_RELEASES': 'true'}), \
             patch.object(release_publisher, 'command', side_effect=command):
            result = release_publisher.post_release_actions('v3.0.29', '3.0.29', release_sha='a' * 40,
                include_webos_release=True, publish_channels=False)
        self.assertIn('synthetic delivery outage', result['channel_failures'][0])
        self.assertFalse(result['notification_failures'])


if __name__ == '__main__':
    unittest.main()
