#!/usr/bin/env python3
"""Compile and execute native worker fault tests; no SDK, network or game downloads."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--protocol-only', action='store_true', help='Run malformed IPC cases without OS sandbox qualification')
    args = parser.parse_args()
    windows = sys.platform == 'win32'
    compiler = os.environ.get('CXX', 'cl' if windows else 'c++')
    with tempfile.TemporaryDirectory(prefix='pleazyng-romm-tests-') as temporary:
        work = Path(temporary)
        suffix = '.exe' if windows else ''
        def build(name, sources, audio=False):
            output = work / (name + suffix)
            if windows:
                args = [compiler, '/nologo', '/std:c++17', '/EHsc', '/MT', '/DNOMINMAX', '/D_WIN32_WINNT=0x0A00',
                        *(['/DPLEZY_RETRO_TEST_NO_AUDIO'] if audio else []), *[str(ROOT / source) for source in sources],
                        '/Fe:' + str(output), '/link', 'bcrypt.lib', 'userenv.lib', 'advapi32.lib']
            else:
                args = [compiler, '-std=c++17', '-O1', '-pthread', '-D_GNU_SOURCE',
                        *(['-Wno-deprecated-declarations'] if sys.platform == 'darwin' else []),
                        *(['-DPLEZY_RETRO_TEST_NO_AUDIO'] if audio else []),
                        *[str(ROOT / source) for source in sources], '-o', str(output)]
                if sys.platform.startswith('linux'):
                    args.append('-ldl')
            subprocess.run(args, cwd=work, check=True)
            return output
        worker = build('plezy_retro_worker', ['native/games/romm/retro_worker.cpp', 'test/native/romm_fixture_api.cpp'])
        test = build('romm_process_test', ['native/games/romm/retro_proxy.cpp', 'test/native/romm_process_test.cpp'], audio=True)
        environment = dict(os.environ, PLEZY_TEST_SECRET='DUMMY_ENVIRONMENT_CREDENTIAL')
        if not args.protocol_only:
            subprocess.run([test, work / 'fixtures with spaces', 'core'], env=environment, check=True, timeout=90)
        malicious = build('fault_worker', ['test/native/romm_fault_worker.cpp'])
        shutil.copy2(malicious, worker)
        subprocess.run([test, work / 'fixtures with spaces', 'faults'], env=environment, check=True, timeout=90)

if __name__ == '__main__':
    main()
