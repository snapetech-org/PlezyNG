#!/usr/bin/env python3
"""Build the host and pinned software cores consumed by the local Apple pods."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'native/games/romm'
FRAMEWORKS = ('PlezyRetro', 'gambatte_libretro', 'mgba_libretro', 'fceumm_libretro')
SPECS = {
    'ios': [('iphoneos', 'arm64'), ('iphonesimulator', 'arm64;x86_64')],
    'tvos': [('appletvos', 'arm64'), ('appletvsimulator', 'arm64;x86_64')],
    'macos': [('macosx', 'arm64;x86_64')],
}


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def tree_digest(directory):
    """Include framework symlink destinations and executable permissions."""
    checksum = hashlib.sha256()
    for path in sorted(directory.rglob('*')):
        checksum.update(path.relative_to(directory).as_posix().encode() + b'\0')
        checksum.update(str(path.lstat().st_mode & 0o777).encode() + b'\0')
        if path.is_symlink():
            checksum.update(b'link\0' + os.readlink(path).encode())
        elif path.is_file():
            checksum.update(b'file\0')
            with path.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    checksum.update(chunk)
        else:
            checksum.update(b'dir\0')
    return checksum.hexdigest()


def cache_valid(destination, fingerprint):
    try:
        receipt = json.loads((destination / 'build-receipt.json').read_text())
        if receipt['sourceSha256'] != fingerprint:
            return False
        expected = {name + '.xcframework' for name in FRAMEWORKS} | {'notices'}
        if receipt['artifacts'].keys() != expected:
            return False
        return all((destination / name).is_dir()
                   and tree_digest(destination / name) == checksum
                   for name, checksum in receipt['artifacts'].items())
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return False


def source_fingerprint(platform):
    inputs = [Path(__file__), ROOT / 'scripts/games/package_romm_cores.py',
              PACKAGE / 'cores/CMakeLists.txt']
    inputs.extend(path for path in sorted(PACKAGE.glob('*')) if path.is_file())
    checksum = hashlib.sha256(platform.encode())
    for path in inputs:
        checksum.update(path.relative_to(ROOT).as_posix().encode() + b'\0')
        checksum.update(path.read_bytes())
    for command in (['xcodebuild', '-version'], ['cmake', '--version']):
        checksum.update(subprocess.check_output(command))
    return checksum.hexdigest()


def build(platform):
    specs = SPECS[platform]
    destination = PACKAGE / 'apple/Frameworks' / platform
    fingerprint = source_fingerprint(platform)
    if cache_valid(destination, fingerprint):
        return
    work = ROOT / 'build/romm' / platform
    frameworks = {name: [] for name in FRAMEWORKS}
    notices = {}
    for sdk, arch in specs:
        out = work / sdk
        command = ['cmake', '-S', PACKAGE, '-B', out, '-G', 'Xcode',
                   '-DPLEZY_ROMM_BUILD_CORES=ON',
                   '-DCMAKE_OSX_SYSROOT=' + sdk, '-DCMAKE_OSX_ARCHITECTURES=' + arch,
                   '-DCMAKE_OSX_DEPLOYMENT_TARGET=' + {'macos': '13.0', 'ios': '15.5', 'tvos': '15.0'}[platform],
                   '-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO',
                   '-DCMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH=NO',
                   '-DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT=dwarf-with-dsym',
                   '-DFETCHCONTENT_BASE_DIR=' + str(out / 'dependencies')]
        if platform != 'macos':
            command += ['-DCMAKE_SYSTEM_NAME=' + ('iOS' if platform == 'ios' else 'tvOS')]
        run(*command)
        run('cmake', '--build', out, '--config', 'Release', '--parallel', str(os.cpu_count() or 2))
        for name in FRAMEWORKS:
            candidates = [path for path in out.rglob(name + '.framework')
                          if path.parent.name.startswith('Release')]
            if len(candidates) != 1:
                raise RuntimeError(f'Expected one {sdk} slice for {name}, found {len(candidates)}')
            frameworks[name].append(candidates[0])
        notices[sdk] = out / 'cores/notices'
        if not (notices[sdk] / 'romm-cores.json').is_file():
            raise RuntimeError(f'Missing corresponding source and core receipt for {sdk}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Install the entire framework/source set together. A failed slice or
    # xcodebuild leaves the previous complete set available for diagnosis.
    with tempfile.TemporaryDirectory(prefix='plezy-retro-', dir=destination.parent) as temporary:
        prepared = Path(temporary) / platform
        prepared.mkdir()
        for name, slices in frameworks.items():
            args = ['xcodebuild', '-create-xcframework']
            for framework in slices:
                args += ['-framework', framework]
            run(*args, '-output', prepared / (name + '.xcframework'))
        for sdk, source in notices.items():
            shutil.copytree(source, prepared / 'notices' / sdk)
        receipt = {'sourceSha256': fingerprint, 'qualified': False,
                   'artifacts': {path.name: tree_digest(path) for path in prepared.iterdir()}}
        (prepared / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        backup = Path(temporary) / 'previous'
        if destination.exists():
            destination.rename(backup)
        try:
            prepared.rename(destination)
        except OSError:
            if backup.exists():
                backup.rename(destination)
            raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=SPECS)
    build(parser.parse_args().platform)
