#!/usr/bin/env python3
"""Run the actual TV worker/proxy/VFS against an adversarial libretro fixture."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--libretro-include', required=True, type=Path)
    parser.add_argument('--compile-only', action='store_true')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='pleazyng-tv-worker-') as temporary:
        directory = Path(temporary)
        def build(name, sources, flags):
            output = directory / name
            subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-O1', '-pthread', '-D_GNU_SOURCE',
                            '-I' + str(args.libretro_include), *flags,
                            *[str(ROOT / path) for path in sources], '-ldl', '-o', str(output)], check=True)
            return output
        core = build('gambatte_libretro.so', ['test/native/romm_libretro_fixture.cpp'],
                     ['-fPIC', '-shared', '-DPLEZY_TEST_DESCRIPTOR_CORE'])
        build('plezy_retro_worker', ['native/games/romm/retro_worker.cpp', 'native/games/romm/retro_host.cpp'],
              ['-DPLEZY_RETRO_REMOTE_AUDIO', '-DPLEZY_RETRO_DESCRIPTOR_INPUTS', '-DPLEZY_RETRO_DESCRIPTOR_SANDBOX'])
        proxy = build('test', ['native/games/romm/retro_proxy.cpp', 'test/native/romm_process_test.cpp'],
                      ['-DPLEZY_RETRO_TEST_NO_AUDIO', '-DPLEZY_PROCESS_LEGACY_LINUX'])
        if args.compile_only:
            print('Cross-compiled TV worker, proxy and fixture successfully')
            return
        subprocess.run([proxy, directory / 'inputs with spaces', 'descriptor', core], check=True, timeout=60,
                       env=dict(os.environ, PLEZY_TEST_SECRET='DUMMY_ENVIRONMENT_CREDENTIAL'))


if __name__ == '__main__':
    main()
