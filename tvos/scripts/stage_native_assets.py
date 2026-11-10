#!/usr/bin/env python3
"""Build real tvOS native assets; never embed the Flutter hook's iOS binary."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
from urllib.parse import unquote, urlparse
from urllib.request import urlopen
import zipfile


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sqlite_package(root: Path, version: str) -> Path:
    lock = (root / 'pubspec.lock').read_text()
    entry = re.search(r'(?ms)^  sqlite3:\n(.*?)(?=^  \S|\Z)', lock)
    if not entry or f'version: "{version}"' not in entry[1]:
        raise ValueError('Review the tvOS SQLite source pin when upgrading package:sqlite3')
    config = root / '.dart_tool/package_config.json'
    matches = [item for item in json.loads(config.read_text())['packages'] if item['name'] == 'sqlite3']
    if len(matches) != 1:
        raise ValueError('Exactly one resolved sqlite3 package is required')
    uri = urlparse(matches[0]['rootUri'])
    if uri.netloc:
        raise ValueError('SQLite package cannot resolve to a remote file authority')
    if uri.scheme == 'file':
        package = Path(unquote(uri.path))
    elif uri.scheme:
        raise ValueError('SQLite package must be resolved locally')
    else:
        package = (config.parent / unquote(uri.path)).resolve()
    hashes = (package / 'lib/src/hook/asset_hashes.dart').read_text()
    tag = re.search(r"releaseTag\s*=\s*'([^']+)'", hashes)
    if not tag or tag[1] != f'sqlite3-{version}':
        raise ValueError('SQLite hook package differs from the reviewed source pin')
    return package


def compiler_defines(package: Path) -> list[str]:
    description = (package / 'lib/src/hook/compile/description.dart').read_text()
    match = re.search(r"const _defaultDefines = '''(.*?)''';", description, re.S)
    if not match:
        raise ValueError('Cannot determine the locked SQLite hook compile options')
    defines = match[1].split()
    if not defines or any(not re.fullmatch(r'SQLITE_[A-Z0-9_]+(?:=[A-Za-z0-9_]+)?', item) for item in defines):
        raise ValueError('Unexpected SQLite compile options')
    return defines


def required_symbols(package: Path, defines: list[str]) -> set[str]:
    symbols = set(re.findall(r"'(sqlite3\w*)'", (package / 'lib/src/hook/compile/used_symbols.dart').read_text()))
    # The Dart binding tests ENABLE_COLUMN_METADATA before using this optional
    # API. Match that behavior without changing the package's default features.
    if 'SQLITE_ENABLE_COLUMN_METADATA' not in {item.split('=')[0] for item in defines}:
        symbols.discard('sqlite3_column_table_name')
    if not symbols:
        raise ValueError('SQLite Dart FFI export list is missing')
    return symbols


def sqlite_source(root: Path, pin: dict) -> Path:
    cache = root / '.dart_tool/tvos-native/sqlite'
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / (pin['archiveSha256'] + '.zip')
    if archive.is_symlink():
        raise ValueError('Refusing linked SQLite source cache')
    if not archive.exists() or digest(archive) != pin['archiveSha256']:
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as output:
            temporary = Path(output.name)
            try:
                with urlopen(pin['archiveUrl'], timeout=60) as response:
                    shutil.copyfileobj(response, output)
                output.flush()
                if digest(temporary) != pin['archiveSha256']:
                    raise ValueError('SQLite source checksum mismatch')
                temporary.replace(archive)
            finally:
                temporary.unlink(missing_ok=True)
    source = cache / 'sqlite3.c'
    with zipfile.ZipFile(archive) as bundle:
        # Read only the exact pinned member; no untrusted archive extraction.
        contents = bundle.read(pin['archiveRoot'] + '/sqlite3.c')
    if f'#define SQLITE_VERSION        "{pin["sqliteVersion"]}"'.encode() not in contents:
        raise ValueError('SQLite amalgamation version differs from its source pin')
    source.write_bytes(contents)
    return source


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True)


def validate_binary(binary: Path, platform: str, architectures: list[str], symbols: set[str]) -> None:
    if set(run('xcrun', 'lipo', '-archs', str(binary)).split()) != set(architectures):
        raise ValueError('SQLite native asset architecture mismatch')
    expected = '8' if platform == 'appletvsimulator' else '3'
    platforms = re.findall(r'^\s*platform\s+(\d+)\s*$', run('xcrun', 'otool', '-arch', 'all', '-l', str(binary)), re.M)
    if not platforms or set(platforms) != {expected}:
        raise ValueError('SQLite must contain genuine tvOS platform load commands')
    exports = {line.split()[-1].removeprefix('_') for line in run('xcrun', 'nm', '-gU', str(binary)).splitlines() if line.split()}
    if missing := symbols - exports:
        raise ValueError(f'Bundled SQLite is missing Dart FFI symbols: {sorted(missing)}')


def stage(root: Path, input_dir: Path, output_dir: Path, platform: str, architectures: list[str], minimum: str) -> None:
    if platform not in {'appletvos', 'appletvsimulator'} or not re.fullmatch(r'\d+(?:\.\d+){0,2}', minimum):
        raise ValueError('A real tvOS SDK and deployment target are required')
    if not architectures or any(arch not in {'arm64', 'x86_64'} for arch in architectures):
        raise ValueError('Unsupported tvOS native asset architecture')
    if platform == 'appletvos' and architectures != ['arm64']:
        raise ValueError('tvOS devices require arm64')
    frameworks = sorted(path.name for path in input_dir.glob('*.framework'))
    if frameworks != ['sqlite3.framework']:
        raise ValueError(f'Unported or missing tvOS native assets: {frameworks}')
    template = input_dir / 'sqlite3.framework'
    if template.is_symlink() or any(path.is_symlink() for path in template.rglob('*')):
        raise ValueError('Native asset input must be a materialized framework')
    pin = json.loads((root / 'tvos/sqlite-source.lock.json').read_text())
    package = sqlite_package(root, pin['packageVersion'])
    defines = compiler_defines(package)
    symbols = required_symbols(package, defines)
    source = sqlite_source(root, pin)
    sdk = run('xcrun', '--sdk', platform, '--show-sdk-path').strip()
    output_dir.mkdir(parents=True, exist_ok=True)
    if output_dir.is_symlink():
        raise ValueError('Refusing linked native asset output')
    with tempfile.TemporaryDirectory(prefix='.sqlite-tvos-', dir=output_dir) as scratch:
        scratch = Path(scratch)
        framework = scratch / 'sqlite3.framework'
        shutil.copytree(template, framework)
        shutil.rmtree(framework / '_CodeSignature', ignore_errors=True)
        binaries = []
        for arch in architectures:
            binary = scratch / arch
            triple = f'{arch}-apple-tvos{minimum}' + ('-simulator' if platform == 'appletvsimulator' else '')
            subprocess.run([
                'xcrun', '--sdk', platform, 'clang', '-target', triple, '-isysroot', sdk,
                '-dynamiclib', '-O2', '-fPIC', '-headerpad_max_install_names',
                '-install_name', '@rpath/sqlite3.framework/sqlite3',
                *['-D' + item for item in defines], str(source), '-o', str(binary),
            ], check=True)
            binaries.append(binary)
        executable = framework / 'sqlite3'
        executable.chmod(0o755)
        if len(binaries) == 1:
            shutil.copyfile(binaries[0], executable)
        else:
            subprocess.run(['xcrun', 'lipo', '-create', *map(str, binaries), '-output', str(executable)], check=True)
        validate_binary(executable, platform, architectures, symbols)
        plist = framework / 'Info.plist'
        metadata = plistlib.loads(plist.read_bytes())
        metadata.update(CFBundleExecutable='sqlite3', MinimumOSVersion=minimum,
                        CFBundleSupportedPlatforms=['AppleTVSimulator' if platform == 'appletvsimulator' else 'AppleTVOS'],
                        DTPlatformName=platform)
        for key in ('DTSDKName', 'DTPlatformVersion', 'DTPlatformBuild', 'DTSDKBuild'):
            metadata.pop(key, None)
        plist.chmod(0o644)
        plist.write_bytes(plistlib.dumps(metadata))
        destination = output_dir / 'sqlite3.framework'
        if destination.is_symlink():
            raise ValueError('Refusing linked native asset destination')
        if destination.exists():
            shutil.rmtree(destination)
        receipt = pin | {'platform': platform, 'architectures': architectures, 'minimumOSVersion': minimum,
                         'compileDefines': defines, 'unsignedBinarySha256': digest(framework / 'sqlite3')}
        (framework / 'pleazyng-source.json').write_text(json.dumps(receipt, indent=2) + '\n')
        framework.rename(destination)
        (output_dir / 'sqlite3-build.json').write_text(json.dumps(receipt, indent=2) + '\n')
        print(f'Built SQLite {pin["sqliteVersion"]} for {platform}: {architectures}')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-root', type=Path, required=True)
    parser.add_argument('--input-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--platform', required=True)
    parser.add_argument('--architectures', required=True)
    parser.add_argument('--minimum', required=True)
    args = parser.parse_args()
    stage(args.project_root.resolve(), args.input_dir, args.output_dir, args.platform, args.architectures.split(), args.minimum)


if __name__ == '__main__':
    main()
