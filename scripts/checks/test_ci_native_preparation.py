#!/usr/bin/env python3
"""Guard the prerequisite order that caused exact-head native CI failures."""
from pathlib import Path
import re
import shlex
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github/workflows/ci.yml'


def job(text: str, name: str) -> str:
    match = re.search(rf'^  {re.escape(name)}:\n(.*?)(?=^  [\w-]+:|\Z)', text, re.M | re.S)
    if match is None:
        raise AssertionError(f'Missing CI job: {name}')
    return match.group(1)


def step(text: str, name: str) -> str:
    match = re.search(rf'^      - name: {re.escape(name)}\n(.*?)(?=^      - |\Z)', text, re.M | re.S)
    if match is None:
        raise AssertionError(f'Missing preparation step: {name}')
    return match.group(0)


class NativePreparationOrderTests(unittest.TestCase):
    def test_independent_ci_jobs_can_start_without_waiting_for_other_suites(self):
        workflow = WORKFLOW.read_text()
        for name in ('android-test', 'linux-native-test', 'server'):
            with self.subTest(job=name):
                self.assertNotRegex(job(workflow, name), r'(?m)^    needs:')
                self.assertNotIn('${{ needs.', job(workflow, name))

    def test_desktop_native_builds_use_the_current_application_target(self):
        workflow = WORKFLOW.read_text()
        for platform in ('linux', 'windows'):
            with self.subTest(platform=platform):
                cmake = (ROOT / f'{platform}/CMakeLists.txt').read_text()
                binary = re.search(r'set\(BINARY_NAME "([^"]+)"\)', cmake)
                self.assertIsNotNone(binary)
                build = step(job(workflow, f'{platform}-native-test'),
                             f'Build {platform.title()} native reliability tests')
                self.assertRegex(build, rf'(?m)^\s+{re.escape(binary[1])} [\\`]\s*$')

    def test_desktop_runtime_is_ready_before_flutter_and_cmake(self):
        text = WORKFLOW.read_text()
        for job_name, platform, architectures in (
            ('linux-native-test', 'linux', ['x64']),
            ('linux-packages', 'linux', ['x64']),
            ('windows-native-test', 'windows', ['x64', 'arm64']),
        ):
            with self.subTest(job=job_name):
                body = job(text, job_name)
                prepare = step(body, f'Build bundled MilkRust for {platform.title()}')
                # Runtime staging cannot depend on cache misses or optional flags.
                self.assertNotRegex(prepare, r'(?m)^        if:', msg=prepare)
                self.assertNotIn('continue-on-error', prepare)
                commands = re.findall(r'flutter build (?:linux|windows)\b|cmake -S (?:linux|windows)\b', body)
                self.assertTrue(commands, 'The job must configure the actual app/native targets')
                for command in commands:
                    self.assertLess(body.index(prepare), body.index(command))
                command = prepare.split('        run: ', 1)[1].strip()
                for arch in architectures:
                    args = shlex.split(command.replace('${{ matrix.arch }}', arch))
                    self.assertEqual(args[1], 'scripts/visualizer/build_runtime.py')
                    self.assertEqual(args[args.index('--platform') + 1], platform)
                    self.assertEqual(args[args.index('--architectures') + 1], arch)
                    self.assertEqual(args[args.index('--output') + 1], 'build/visualizer-native')
                if platform == 'windows':
                    self.assertIn('shell: pwsh', prepare)
                    self.assertIn('--architectures "${{ matrix.arch }}"', prepare)

    def test_apple_refresh_follows_pub_get_and_precedes_every_flutter_config(self):
        body = job(WORKFLOW.read_text(), 'apple-native-test')
        dependencies = step(body, 'Install locked Dart dependencies')
        self.assertIn('flutter pub get --enforce-lockfile --no-example', dependencies)
        for platform, slug in (('iOS', 'ios'), ('macOS', 'macos')):
            with self.subTest(platform=platform):
                refresh = step(body, f'Refresh pinned {platform} Swift packages')
                configure = step(body, f'Prepare {platform} Flutter build settings')
                self.assertIn(f"if: matrix.platform == '{platform}'", refresh)
                self.assertIn(f'run: scripts/refresh_apple_spm.sh {slug}', refresh)
                self.assertNotIn('--reset', refresh, 'Refresh must preserve the existing package cache')
                self.assertLess(body.index(dependencies), body.index(refresh))
                self.assertLess(body.index(refresh), body.index(configure))
                for match in re.finditer(rf'flutter build {slug}\b', body):
                    self.assertLess(body.index(refresh), match.start())

    def test_unit_job_is_the_only_full_application_suite(self):
        workflow = WORKFLOW.read_text()
        analysis = job(workflow, 'analyze')
        unit = job(workflow, 'test')
        self.assertNotRegex(analysis, r'flutter test\b|scripts/run_tests\.sh\b')
        self.assertIn('dart run scripts/checks/check_analyzer.dart', step(analysis, 'Analyze code'))
        self.assertEqual(workflow.count('scripts/run_tests.sh'), 1)
        self.assertIn('scripts/run_tests.sh -j 2 --timeout=120s', step(unit, 'Run tests'))
        # These independent suites are intentional coverage, not duplicates.
        for name in (
            'Run real reader browser checks',
            'Run wakelock_plus VM tests',
            'Run wakelock_plus Chrome tests',
            'Run the vendored desktop preference store tests',
        ):
            self.assertTrue(step(unit, name))

    def test_required_runtime_receipts_are_not_bypassed(self):
        workflow = WORKFLOW.read_text()
        for name in ('linux-native-test', 'linux-packages', 'windows-native-test'):
            self.assertNotIn('PLEZY_VISUALIZER_REQUIRE_MILKRUST=OFF', job(workflow, name))
        cmake = (ROOT / 'native/visualizer/milkrust.cmake').read_text()
        self.assertIn('option(PLEZY_VISUALIZER_REQUIRE_MILKRUST "Require the bundled native visualization runtime" ON)', cmake)
        self.assertIn('Staged MilkRust runtime differs from the app source pin', cmake)
        self.assertIn('MilkRust runtime is missing:', cmake)


if __name__ == '__main__':
    unittest.main()
