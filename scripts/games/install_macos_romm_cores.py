#!/usr/bin/env python3
"""Embed worker-only cores without linking their constructors into the app."""
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

CORES = ('gambatte_libretro', 'mgba_libretro', 'fceumm_libretro')
ROOT = Path(__file__).resolve().parents[2]


def core_slice(root, name):
    bundle = root / (name + '.xcframework')
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    slices = [row for row in info.get('AvailableLibraries', [])
              if row.get('SupportedPlatform') == 'macos' and not row.get('SupportedPlatformVariant')]
    if len(slices) != 1 or set(slices[0].get('SupportedArchitectures', [])) != {'arm64', 'x86_64'}:
        raise ValueError('Expected exactly one universal macOS core slice')
    row = slices[0]
    identifier = row.get('LibraryIdentifier', '')
    if not re.fullmatch(r'[A-Za-z0-9_-]+', identifier) or row.get('LibraryPath') != name + '.framework':
        raise ValueError('Invalid core framework slice path')
    source = bundle / identifier / row['LibraryPath']
    if source.is_symlink() or not source.is_dir() or not (source / name).is_file():
        raise ValueError('Core framework binary is missing')
    if not source.resolve().is_relative_to(bundle.resolve()):
        raise ValueError('Core framework escapes its source bundle')
    # Versioned frameworks contain symlinks; keep only links within the slice.
    for path in source.rglob('*'):
        if path.is_symlink() and not path.resolve(strict=True).is_relative_to(source.resolve()):
            raise ValueError('Core framework contains an external symlink')
    return source


def install(root, destination, *, identity=None):
    sources = [core_slice(root, name) for name in CORES]
    destination.mkdir(parents=True, exist_ok=True)
    for source in sources:
        target = destination / source.name
        if target.is_symlink():
            raise ValueError('Refusing a linked core installation destination')
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(source, target, symlinks=True)
        if identity is not None:
            subprocess.run(['codesign', '--force', '--sign', identity, '--options', 'runtime',
                            '--timestamp=none' if identity == '-' else '--timestamp', str(target)], check=True)


def verify_app_linkage(executable):
    dependencies = subprocess.check_output(['otool', '-L', str(executable)], text=True)
    if any(name + '.framework/' in dependencies for name in CORES):
        raise ValueError('The app must not link emulator cores; only the isolated worker may load them')


if __name__ == '__main__':
    build = Path(os.environ['TARGET_BUILD_DIR'])
    verify_app_linkage(build / os.environ['EXECUTABLE_PATH'])
    install(ROOT / 'native/games/romm/apple/Frameworks/macos',
            build / os.environ['FRAMEWORKS_FOLDER_PATH'],
            identity=(os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-')
            if os.environ.get('CODE_SIGNING_ALLOWED', 'YES') == 'YES' else None)
