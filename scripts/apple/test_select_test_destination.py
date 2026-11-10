import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from select_test_destination import cleanup_device, create_fresh_device, select_device_template


class DestinationTests(unittest.TestCase):
    uid = '12345678-1234-1234-1234-123456789ABC'

    def env(self, temp):
        return {'RUNNER_TEMP': temp, 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1',
                'GITHUB_JOB': 'apple-native-test', 'GITHUB_SHA': 'a' * 40, 'SIMULATOR_RUNTIME': 'tvOS'}

    def create(self, env):
        with patch('select_test_destination.simctl', return_value=self.uid) as command:
            result = create_fresh_device(self.payload(), 'tvOS', '26.2', env)
        self.assertEqual(command.call_args.args[0], 'create')
        self.assertIn(self.uid, result[0])
        return result[2]

    def payload(self):
        runtimes = [
            {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-18-5', 'version': '18.5', 'isAvailable': True},
            {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-2', 'version': '26.2', 'isAvailable': True},
            {'identifier': 'com.apple.CoreSimulator.SimRuntime.tvOS-26-2', 'version': '26.2', 'isAvailable': True},
        ]
        return {'runtimes': runtimes, 'devices': {
            runtime['identifier']: [{'name': 'iPhone' if '.iOS-' in runtime['identifier'] else 'Apple TV',
                                    'udid': f'00000000-0000-0000-0000-{i + 1:012d}', 'isAvailable': True,
                                    'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.Test'}]
            for i, runtime in enumerate(runtimes)}}

    def test_old_first_runtime_does_not_override_the_selected_sdk(self):
        runtime, _ = select_device_template(self.payload(), 'iOS', '26.2')
        self.assertEqual(runtime['version'], '26.2')
        self.assertIn('.iOS-', runtime['identifier'])

    def test_tvos_selects_its_own_matching_runtime(self):
        runtime, _ = select_device_template(self.payload(), 'tvOS', '26.2')
        self.assertIn('.tvOS-', runtime['identifier'])

    def test_missing_or_unavailable_sdk_runtime_fails_without_older_fallback(self):
        with self.assertRaisesRegex(ValueError, 'matches selected SDK'):
            select_device_template(self.payload(), 'iOS', '27.0')
        payload = self.payload()
        payload['runtimes'][1]['isAvailable'] = False
        with self.assertRaisesRegex(ValueError, 'matches selected SDK'):
            select_device_template(payload, 'iOS', '26.2')

    def test_fresh_device_receipt_cannot_be_replaced(self):
        with tempfile.TemporaryDirectory() as temp:
            env = self.env(temp)
            receipt = self.create(env)
            self.assertEqual(json.loads(receipt.read_text())['owner']['GITHUB_SHA'], 'a' * 40)
            with patch('select_test_destination.simctl') as command:
                with self.assertRaisesRegex(ValueError, 'already exists'):
                    create_fresh_device(self.payload(), 'tvOS', '26.2', env)
                command.assert_not_called()

    def test_cleanup_deletes_only_owned_device_and_preserves_existing_template(self):
        with tempfile.TemporaryDirectory() as temp:
            env = self.env(temp)
            receipt = self.create(env)
            record = json.loads(receipt.read_text())
            inventory = self.payload()
            inventory['devices'][record['runtime']].append(
                {'udid': self.uid, 'name': record['name'], 'state': 'Booted',
                 'deviceTypeIdentifier': record['device_type']})
            with patch('select_test_destination.simctl', side_effect=[json.dumps(inventory), '', '']) as command:
                cleanup_device(env)
                self.assertEqual([call.args for call in command.call_args_list],
                                 [('list', '-j'), ('shutdown', self.uid), ('delete', self.uid)])
            self.assertEqual(json.loads(receipt.read_text())['state'], 'deleted')

    def test_cancelled_job_retains_device_without_any_simulator_operation(self):
        with tempfile.TemporaryDirectory() as temp:
            env = self.env(temp)
            self.create(env)
            env['APPLE_JIT_JOB_STATUS'] = 'cancelled'
            with patch('select_test_destination.simctl') as command:
                cleanup_device(env)
                command.assert_not_called()

    def test_owner_or_device_identity_mismatch_refuses_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            env = self.env(temp)
            receipt = self.create(env)
            with patch('select_test_destination.simctl') as command:
                with self.assertRaisesRegex(ValueError, 'owner'):
                    cleanup_device(dict(env, GITHUB_SHA='b' * 40))
                command.assert_not_called()
            record = json.loads(receipt.read_text())
            inventory = {'devices': {record['runtime']: [{'udid': self.uid, 'name': 'someone else'}]}}
            with patch('select_test_destination.simctl', return_value=json.dumps(inventory)) as command:
                with self.assertRaisesRegex(ValueError, 'identity differs'):
                    cleanup_device(env)
                self.assertEqual(command.call_count, 1)

    def test_failed_process_drain_preserves_simulator(self):
        with tempfile.TemporaryDirectory() as temp:
            env = self.env(temp)
            self.create(env)
            helper = Path(temp) / '.apple-jit-process-tree.py'
            helper.touch()
            env.update(APPLE_JIT_PROCESS_HELPER=str(helper), APPLE_JIT_PROCESS_RUNNER_ROOT=temp,
                       APPLE_JIT_PROCESS_JOB_ID='456')
            with patch('select_test_destination.subprocess.run', side_effect=RuntimeError('busy')):
                with patch('select_test_destination.simctl') as command:
                    with self.assertRaisesRegex(RuntimeError, 'busy'):
                        cleanup_device(env)
                    command.assert_not_called()


if __name__ == '__main__':
    unittest.main()
