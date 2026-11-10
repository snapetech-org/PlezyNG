#!/usr/bin/env python3
"""An explicitly requested sanitizer must never become an unsanitized pass."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SanitizerConfigurationTests(unittest.TestCase):
    def configure(self, mode, compiler='GNU'):
        source = (ROOT / 'linux/runner/CMakeLists.txt').read_text()
        function = re.search(r'(?ms)^function\(apply_mpv_reliability_sanitizer TARGET\).*?^endfunction\(\)', source)
        self.assertIsNotNone(function)
        with tempfile.TemporaryDirectory(prefix='pleazyng-sanitizer-contract-') as directory:
            root = Path(directory)
            (root / 'CMakeLists.txt').write_text(
                'cmake_minimum_required(VERSION 3.20)\nproject(sanitizer_contract NONE)\n'
                f'set(CMAKE_CXX_COMPILER_ID "{compiler}")\n'
                f'set(PLEZY_MPV_RELIABILITY_SANITIZER "{mode}")\n'
                'function(check_mpv_sanitizer_support FLAG RESULT)\n'
                '  set(${RESULT} FALSE PARENT_SCOPE)\nendfunction()\n'
                + function.group() + '\napply_mpv_reliability_sanitizer(unbuilt_target)\n')
            return subprocess.run(['cmake', '-S', str(root), '-B', str(root / 'build')],
                                  capture_output=True, text=True)

    def test_missing_explicit_sanitizer_fails_configuration(self):
        for mode in ('address', 'thread'):
            with self.subTest(mode=mode):
                result = self.configure(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f'Requested {mode} sanitizer is unavailable', result.stderr)

    def test_unsupported_compiler_cannot_silently_disable_requested_instrumentation(self):
        result = self.configure('thread', 'Unsupported')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires Clang or GNU', result.stderr)

    def test_explicit_none_preserves_the_unsanitized_configuration(self):
        result = self.configure('none', 'Unsupported')
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
