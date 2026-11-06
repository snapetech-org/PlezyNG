#!/usr/bin/env python3
"""The shared client SDK must work without FFmpeg's private source-build SDKs."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from fetch_linux_libmpv import configure_shared_client_sdk


class SharedClientSDKTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('pkg-config'), 'pkg-config required')
    def test_real_pkg_config_resolves_only_the_public_shared_client(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / 'lib/x86_64-linux-gnu/pkgconfig'
            directory.mkdir(parents=True)
            pc = directory / 'mpv.pc'
            pc.write_text('prefix=${pcfiledir}/../../..\nlibdir=${prefix}/lib/x86_64-linux-gnu\n'
                          'includedir=${prefix}/include\nName: mpv\nDescription: shared client\nVersion: 2.6.0\n'
                          'Requires.private: missing-lua52, missing-protocols >= 99\n'
                          'Libs: -L${libdir} -lmpv\nLibs.private: -lproducer-only\nCflags: -I${includedir}\n')
            environment = {**os.environ, 'PKG_CONFIG_PATH': str(directory), 'PKG_CONFIG_LIBDIR': str(directory)}
            command = ['pkg-config', '--cflags', '--libs', 'mpv']
            before = subprocess.run(command, env=environment, capture_output=True, text=True)
            self.assertNotEqual(before.returncode, 0)
            configure_shared_client_sdk(root)
            after = subprocess.run(command, env=environment, capture_output=True, text=True, check=True)
            self.assertIn('-lmpv', after.stdout)
            self.assertIn('-rpath-link,', after.stdout)
            self.assertNotIn('producer-only', after.stdout)
            self.assertIn('Version: 2.6.0', pc.read_text())
            configured = pc.read_bytes()
            configure_shared_client_sdk(root)
            self.assertEqual(pc.read_bytes(), configured)


if __name__ == '__main__':
    unittest.main()
