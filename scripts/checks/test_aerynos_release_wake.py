"""Automatic aerynOS delivery follows successful core publication."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_all_platforms as release


class AerynosWakeTests(unittest.TestCase):
    def test_published_core_wakes_consumer_without_manual_channel_selection(self):
        with patch.object(release, 'dispatch_automatic_play', return_value=None), \
                patch.object(release, 'command') as command:
            result = release.post_release_actions('v3.0.30', '3.0.30', release_sha='a' * 40,
                                                   include_webos_release=True, publish_channels=False)
        calls = [call.args[0] for call in command.call_args_list]
        wakes = [args for args in calls if 'snapetech-org/pleazyng-aerynos' in args]
        self.assertEqual(wakes, [['gh', 'workflow', 'run', 'reconcile.yml', '--repo',
                                  'snapetech-org/pleazyng-aerynos', '--ref', 'main']])
        self.assertEqual(result['aerynos_automation'][0]['state'], 'dispatched')
        self.assertFalse(result['channel_failures'])
        self.assertFalse(any('build.yml' in args or 'aerynos-candidate.yml' in args for args in calls))

    def test_consumer_wake_failure_is_retryable_delivery_and_preserves_core_success(self):
        def command(args):
            if 'snapetech-org/pleazyng-aerynos' in args:
                raise release.ReleaseError('consumer temporarily unavailable')
        with patch.object(release, 'dispatch_automatic_play', return_value=None), \
                patch.object(release, 'command', side_effect=command):
            result = release.post_release_actions('v3.0.30', '3.0.30', release_sha='a' * 40,
                                                   include_webos_release=True, publish_channels=False)
        self.assertEqual(result['aerynos_automation'], [])
        self.assertIn('Automatic aerynOS delivery', result['channel_failures'][0])
        self.assertFalse(result['notification_failures'])


if __name__ == '__main__':
    unittest.main()
