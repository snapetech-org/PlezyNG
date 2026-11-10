import unittest

from select_test_destination import select_device


class DestinationTests(unittest.TestCase):
    def payload(self):
        runtimes = [
            {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-18-5', 'version': '18.5', 'isAvailable': True},
            {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-2', 'version': '26.2', 'isAvailable': True},
            {'identifier': 'com.apple.CoreSimulator.SimRuntime.tvOS-26-2', 'version': '26.2', 'isAvailable': True},
        ]
        return {'runtimes': runtimes, 'devices': {
            runtime['identifier']: [{'name': 'iPhone' if '.iOS-' in runtime['identifier'] else 'Apple TV',
                                    'udid': f'00000000-0000-0000-0000-{i + 1:012d}', 'isAvailable': True}]
            for i, runtime in enumerate(runtimes)}}

    def test_old_first_runtime_does_not_override_the_selected_sdk(self):
        destination, runtime = select_device(self.payload(), 'iOS', '26.2')
        self.assertEqual(runtime, '26.2')
        self.assertIn('000000000002', destination)

    def test_tvos_selects_its_own_matching_runtime(self):
        destination, runtime = select_device(self.payload(), 'tvOS', '26.2')
        self.assertEqual(runtime, '26.2')
        self.assertIn('000000000003', destination)

    def test_missing_or_unavailable_sdk_runtime_fails_without_older_fallback(self):
        with self.assertRaisesRegex(ValueError, 'matches selected SDK'):
            select_device(self.payload(), 'iOS', '27.0')
        payload = self.payload()
        payload['runtimes'][1]['isAvailable'] = False
        with self.assertRaisesRegex(ValueError, 'matches selected SDK'):
            select_device(payload, 'iOS', '26.2')


if __name__ == '__main__':
    unittest.main()
