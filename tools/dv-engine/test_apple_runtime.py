import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import build_apple_runtime as runtime


class AppleRuntimeEnvironmentTest(unittest.TestCase):
    def test_package_graph_abort_retries_once_from_clean_task_state(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            for name in ('SourcePackages', 'DerivedData'):
                target = work / name
                target.mkdir()
                (target / 'partial').write_text('stale')
            failure = subprocess.CalledProcessError(-signal.SIGABRT, ['xcodebuild'])
            with patch('build_apple_runtime.run', side_effect=(failure, None)) as mocked:
                runtime.resolve_packages(['xcodebuild'], work, {'PATH': '/tools'})
            self.assertEqual(mocked.call_count, 2)
            self.assertFalse((work / 'SourcePackages').exists())
            self.assertFalse((work / 'DerivedData').exists())

    def test_ordinary_package_resolution_failure_is_not_retried(self):
        with tempfile.TemporaryDirectory() as directory:
            failure = subprocess.CalledProcessError(65, ['xcodebuild'])
            with patch('build_apple_runtime.run', side_effect=failure) as mocked:
                with self.assertRaises(subprocess.CalledProcessError):
                    runtime.resolve_packages(['xcodebuild'], Path(directory), {})
            mocked.assert_called_once()

    def test_discards_outer_app_settings_but_keeps_execution_and_fetch_settings(self):
        keep = {
            'HOME': '/Users/builder', 'PATH': '/opt/homebrew/bin:/usr/bin',
            'TMPDIR': '/task/tmp', 'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer',
            'SSH_AUTH_SOCK': '/private/agent.sock', 'LANG': 'en_US.UTF-8',
            'LC_ALL': 'en_US.UTF-8', 'HTTPS_PROXY': 'https://proxy.invalid',
            'SSL_CERT_FILE': '/task/ca.pem', 'GIT_SSH_COMMAND': 'ssh -F /task/config',
        }
        outer = {
            'EXECUTABLE_DEBUG_DYLIB_PATH': 'Pleazyng.app/Pleazyng.debug.dylib',
            'EXECUTABLE_BLANK_INJECTION_DYLIB_PATH': 'Pleazyng.app/__preview.dylib',
            'EXECUTABLE_DEBUG_DYLIB_INSTALL_NAME': '@rpath/Pleazyng.debug.dylib',
            'ENABLE_DEBUG_DYLIB': 'YES', 'PRODUCT_NAME': 'Pleazyng',
            'SDKROOT': '/outer/SDK', 'ARCHS': 'wrong-arch', 'CC': '/outer/compiler',
            'SWIFT_EXEC': '/outer/swift', 'OTHER_LDFLAGS': '-lOuter',
            'XCODE_XCCONFIG_FILE': '/outer/override.xcconfig',
            'TARGET_BUILD_DIR': '/outer/products', 'EXPANDED_CODE_SIGN_IDENTITY': 'outer-identity',
        }
        base = {**keep, **outer}
        result = runtime.build_environment(base)
        self.assertEqual({key: result[key] for key in keep}, keep)
        self.assertTrue(outer.keys().isdisjoint(result))
        self.assertEqual(base, {**keep, **outer})

    def test_appends_lfs_configuration_without_mutating_parent(self):
        base = {'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'url.https://mirror/.insteadOf',
                'GIT_CONFIG_VALUE_0': 'https://github.com/'}
        before = dict(base)
        env = runtime.build_environment(base)
        self.assertEqual(base, before)
        self.assertEqual(env['GIT_CONFIG_COUNT'], '5')
        self.assertEqual(env['GIT_CONFIG_KEY_0'], base['GIT_CONFIG_KEY_0'])
        self.assertEqual(env['GIT_CONFIG_KEY_1'], 'filter.lfs.process')
        self.assertEqual(env['GIT_CONFIG_VALUE_1'], 'git-lfs filter-process')
        self.assertEqual(env['GIT_CONFIG_VALUE_2'], 'true')
        self.assertEqual(runtime.build_environment(base), env)

    @patch('build_apple_runtime.platform.system', return_value='Darwin')
    @patch('build_apple_runtime.shutil.which', return_value='/tool')
    def test_generator_resolver_and_compiler_share_isolation_and_preserve_parent(self, *_):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            parent = {'PATH': '/tools', 'HOME': '/builder',
                      'EXECUTABLE_DEBUG_DYLIB_PATH': 'Pleazyng.app/Pleazyng.debug.dylib',
                      'EXPANDED_CODE_SIGN_IDENTITY': 'outer-identity'}
            products = work / 'DerivedData/Build/Products/Debug-iphonesimulator'

            def run(command, **kwargs):
                if command[-1] == 'build':
                    (products / 'PackageFrameworks/PlezyNGDVRuntime.framework').mkdir(parents=True)
                    for name in ('AetherEngine', 'FFmpegBuild', 'LibDovi'):
                        checkout = work / 'SourcePackages/checkouts' / name
                        checkout.mkdir(parents=True)
                        (checkout / 'LICENSE').write_text(name + ' notice')

            with patch.dict(os.environ, parent, clear=True), patch('build_apple_runtime.run', side_effect=run) as mocked:
                self.assertEqual(runtime.build(work, 'iphonesimulator', 'Debug', ['arm64']), products)
                self.assertEqual(dict(os.environ), parent)
            self.assertEqual(mocked.call_count, 3)
            for call in mocked.call_args_list:
                self.assertNotIn('EXECUTABLE_DEBUG_DYLIB_PATH', call.kwargs['env'])
                self.assertNotIn('EXPANDED_CODE_SIGN_IDENTITY', call.kwargs['env'])
                self.assertEqual(call.kwargs['env']['HOME'], '/builder')
                self.assertEqual(call.kwargs['env']['GIT_CONFIG_COUNT'], '4')
            command = mocked.call_args_list[-1].args[0]
            self.assertIn('ARCHS=arm64', command)
            self.assertIn('CODE_SIGNING_ALLOWED=NO', command)
            self.assertIn('-onlyUsePackageVersionsFromResolvedFile', command)
            spec = json.loads((work / 'project.json').read_text())
            self.assertEqual(spec['targets']['PlezyNGDVBuild']['dependencies'],
                             [{'package': 'Runtime', 'product': 'PlezyNGDVRuntime'}])
            provenance = json.loads((products / 'PlezyNGDVRuntime.provenance.json').read_text())
            self.assertEqual(provenance['traits'], ['DualLayerDolbyVision'])
            self.assertEqual(provenance['qualification'], 'unqualified')
            self.assertEqual(len(list((products / 'PlezyNGDVRuntime-Licenses').iterdir())), 3)


if __name__ == '__main__':
    unittest.main()
