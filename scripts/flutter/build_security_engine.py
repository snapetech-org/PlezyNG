#!/usr/bin/env python3
"""Build the existing Windows presentation patches on the fixed Flutter SDK.

The upstream patch series is fetched at an immutable revision. Sources and
tooling stay under --workspace; no installed SDK or shared runner cache changes.
See GHSA-frr6-h895-5pxp and UPSTREAM_ATTRIBUTION.md.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

VERSION = '3.47.8'
FRAMEWORK = '737ba8f885dc774b53b442759999a312c9461e4e'
ENGINE = 'cf636b1dfb818dd6a3ff16e390e93b1a036969c8'
DART = '416e33b0ffaef062a60ec966bb8c82ed2b83f128'
SKIA = '8df24be66531469e576a806749a0202ae26b8d08'
PATCHES = '06654fe6ff3fff67fdaa74e2a7c41ecbbc90bee2'
DEPOT = '580b4ff3f5cd0dcaa2eacda28cefe0f45320e8f7'


def run(*args, cwd=None):
    subprocess.run([str(x) for x in args], cwd=cwd, check=True)


def revision(path):
    return subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip()


def checkout(url, sha, destination):
    if destination.exists():
        raise RuntimeError(f'Refusing to reuse a source directory: {destination}')
    run('git', 'init', destination)
    run('git', '-C', destination, 'remote', 'add', 'origin', url)
    run('git', '-C', destination, 'fetch', '--depth=1', 'origin', sha)
    run('git', '-C', destination, 'checkout', '--detach', 'FETCH_HEAD')
    if revision(destination) != sha:
        raise RuntimeError('Source pin mismatch')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--arch', choices=['x64', 'arm64'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'win32':
        parser.error('The Windows engine requires a Windows build host')
    root = args.workspace.resolve()
    root.mkdir(parents=True, exist_ok=False)
    source = root / 'patches'
    checkout('https://github.com/edde746/flutter-plezy.git', PATCHES, source)
    depot = source / 'depot_tools'
    checkout('https://chromium.googlesource.com/chromium/tools/depot_tools.git', DEPOT, depot)
    os.environ.update(DEPOT_TOOLS_UPDATE='0', DEPOT_TOOLS_WIN_TOOLCHAIN='0',
                      GIT_CONFIG_COUNT='2', GIT_CONFIG_KEY_0='user.name',
                      GIT_CONFIG_VALUE_0='Pleazyng engine builder',
                      GIT_CONFIG_KEY_1='user.email',
                      GIT_CONFIG_VALUE_1='engine-build@users.noreply.github.com')
    os.environ['PATH'] = str(depot) + os.pathsep + os.environ['PATH']
    destination = source / 'versions' / VERSION
    shutil.copytree(source / 'versions' / '3.47.1', destination)
    # Only Windows patches are applied. The upstream Apple port remains intact.
    (destination / 'sdk.lock').write_text(
        f'FLUTTER_VERSION={VERSION}\nENGINE_REPO=https://github.com/flutter/flutter.git\n'
        f'ENGINE_REF={FRAMEWORK}\nENGINE_COMMIT={FRAMEWORK}\n'
        f'DART_COMMIT={DART}\nSKIA_COMMIT={SKIA}\n', encoding='utf-8')
    run(sys.executable, source / 'engine.py', 'fetch', VERSION, cwd=source)
    monorepo = source / 'sources' / VERSION
    if revision(monorepo) != FRAMEWORK:
        raise RuntimeError('Flutter source differs from the fixed release')
    flutter = monorepo / 'engine' / 'src' / 'flutter'
    if revision(flutter / 'third_party' / 'dart') != DART or revision(flutter / 'third_party' / 'skia') != SKIA:
        raise RuntimeError('Transitive SDK pins do not match the fixed release')
    if (monorepo / 'bin/internal/engine.version').read_text().strip() != ENGINE:
        raise RuntimeError('Unexpected engine ABI')
    run(sys.executable, source / 'engine.py', 'apply', VERSION, '--platform', 'windows', cwd=source)
    suffix = '_arm64' if args.arch == 'arm64' else ''
    for mode in ['debug', 'release']:
        run(sys.executable, source / 'engine.py', 'build', VERSION, f'host_{mode}{suffix}', cwd=source)
    args.output.mkdir(parents=True, exist_ok=True)
    archive = args.output / f'flutter-pleazyng-windows-{VERSION}-{args.arch}.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
        for mode in ['debug', 'release']:
            directory = source / 'out' / VERSION / f'host_{mode}{suffix}' / 'zip_archives'
            matches = list(directory.rglob(f'windows-{args.arch}-flutter.zip'))
            if len(matches) != 1:
                raise RuntimeError(f'Expected one {mode} engine archive, found {matches}')
            cache = f'windows-{args.arch}' + ('-release' if mode == 'release' else '')
            with zipfile.ZipFile(matches[0]) as built:
                names = built.namelist()
                if 'flutter_windows.dll' not in names:
                    raise RuntimeError('Engine archive lacks its runtime')
                for item in built.infolist():
                    if item.is_dir():
                        continue
                    name = item.filename
                    if name.startswith(('/', '\\')) or '..' in name.replace('\\', '/').split('/') or ':' in name:
                        raise RuntimeError('Unsafe engine archive member')
                    output.writestr(f'{cache}/{name}', built.read(item))
        output.writestr('LICENSE.flutter-plezy', (source / 'LICENSE').read_bytes())
        output.writestr('pleazyng-engine-provenance.json', json.dumps({
            'frameworkVersion': VERSION, 'frameworkRevision': FRAMEWORK,
            'engineRevision': ENGINE, 'dartRevision': DART, 'skiaRevision': SKIA,
            'patchSource': 'https://github.com/edde746/flutter-plezy',
            'patchRevision': PATCHES, 'depotRevision': DEPOT, 'architecture': args.arch,
            'advisory': 'GHSA-frr6-h895-5pxp',
        }, indent=2) + '\n')
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (args.output / f'{archive.name}.sha256').write_text(f'{digest}  {archive.name}\n')
    print(f'ENGINE_ARTIFACT {archive.name} {digest}', flush=True)


if __name__ == '__main__':
    main()
