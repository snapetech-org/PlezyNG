#!/usr/bin/env python3
"""Compile the real iOS extension, broker, proxy and descriptor worker."""
import os
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def run(*args):
    subprocess.run([str(value) for value in args], cwd=ROOT, check=True)


def main():
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    arch = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
    extension = ROOT / 'native/games/romm/apple/extension'
    for source, minimum in [('HostBroker.swift', '15.5'), ('RommWorkerExtension.swift', '26.0')]:
        run('xcrun', 'swiftc', '-typecheck', '-parse-as-library', '-swift-version', '5',
            '-sdk', sdk, '-target', f'{arch}-apple-ios{minimum}-simulator', extension / source)
    out = ROOT / 'build/romm-extension-compile'
    run('cmake', '-S', ROOT / 'native/games/romm', '-B', out, '-G', 'Xcode',
        '-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_OSX_SYSROOT=iphonesimulator',
        '-DCMAKE_OSX_ARCHITECTURES=' + arch, '-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0',
        '-DPLEZY_ROMM_APPLE_EXTENSION=ON', '-DPLEZY_ROMM_BUILD_CORES=OFF',
        '-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO')
    run('cmake', '--build', out, '--config', 'Release', '--parallel', str(os.cpu_count() or 2))
    print('Compiled iOS broker, enhanced-security extension and production native targets; runtime qualification pending.')


if __name__ == '__main__':
    main()
