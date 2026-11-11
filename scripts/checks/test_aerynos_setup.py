"""Exercise the real native QA provisioning shell without package/VM side effects."""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def step(name):
    workflow = (ROOT / '.github/workflows/aerynos-qualify.yml').read_text()
    return workflow.split('      - name: ' + name + '\n', 1)[1].split('\n      - ', 1)[0]


class AerynosSetupTests(unittest.TestCase):
    def exercise(self, healthy):
        block = step('Install native VM and fixture tools')
        run = block.split('        run: |\n', 1)[1]
        lines = []
        for line in run.splitlines():
            if not line.startswith('          '):
                break
            lines.append(line[10:])
        script = '\n'.join(lines).replace('${{ runner.environment }}', 'github-hosted')
        self.assertTrue(script)
        # The subsequent native step uses GitHub's default success condition.
        native = step('Native build install and visible release playback')
        self.assertIsNone(re.search(r'^        if:', native, re.MULTILINE),
                          'native QA must not run after failed setup')
        self.assertNotIn('continue-on-error:', block)
        with tempfile.TemporaryDirectory(prefix='aerynos setup ') as directory:
            root = Path(directory)
            commands = {
                'sudo': '#!/bin/bash\ncase "$1" in\n'
                        'python3) printf "configure\\n" >> "$SETUP_LOG";;\n'
                        'apt-get) shift; exec "$SETUP_BIN/apt-get" "$@";;\n'
                        '*) exit 97;;\nesac\n',
                'apt-get': '#!/bin/bash\nprintf "%s\\n" "$*" >> "$SETUP_LOG"\n'
                           'if [[ "$1" == update && "$INDEX_HEALTHY" != 1 ]]; then\n'
                           '  echo "Temporary failure resolving archive.ubuntu.com" >&2\n'
                           '  for argument in "$@"; do\n'
                           '    [[ "$argument" != --error-on=any ]] || exit 100\n'
                           '  done\nfi\nexit 0\n',
                'df': '#!/bin/bash\nexit 0\n',
            }
            for name, text in commands.items():
                path = root / name
                path.write_text(text)
                path.chmod(0o755)
            log = root / 'calls.log'
            # No host KVM dependency or access: only the ordinary availability check is simulated.
            prefix = 'test() { if [[ "$*" == "-e /dev/kvm" ]]; then return 0; fi; builtin test "$@"; }\n'
            result = subprocess.run(['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c',
                                     prefix + script + '\nprintf "native\\n" >> "$SETUP_LOG"'],
                                    cwd=root, capture_output=True, text=True,
                                    env={**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                                         'SETUP_BIN': str(root), 'SETUP_LOG': str(log),
                                         'RUNNER_TEMP': str(root), 'INDEX_HEALTHY': '1' if healthy else '0'})
            return result, log.read_text().splitlines()

    def test_failed_index_refresh_prevents_install_and_native_qa(self):
        result, calls = self.exercise(False)
        self.assertEqual(result.returncode, 100, result.stderr)
        self.assertIn('Temporary failure resolving', result.stderr)
        self.assertEqual(calls[0], 'configure')
        self.assertTrue(calls[1].startswith('update '), calls)
        self.assertEqual(len(calls), 2, 'failed indexes must stop before package install or native QA')

    def test_healthy_indexes_install_dependencies_before_native_qa(self):
        result, calls = self.exercise(True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[0], 'configure')
        self.assertTrue(calls[1].startswith('update '), calls)
        self.assertTrue(calls[2].startswith('install '), calls)
        self.assertEqual(calls[3:], ['native'])

    def test_tool_setup_has_a_separate_ten_minute_budget(self):
        match = re.search(r'^        timeout-minutes: (\d+)$',
                          step('Install native VM and fixture tools'), re.MULTILINE)
        self.assertIsNotNone(match)
        self.assertEqual(int(match.group(1)), 10)


if __name__ == '__main__':
    unittest.main()
