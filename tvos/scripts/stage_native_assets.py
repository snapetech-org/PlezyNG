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


def resolved_package(root: Path, name: str, version: str) -> Path:
    lock = (root / 'pubspec.lock').read_text()
    entry = re.search(rf'(?ms)^  {re.escape(name)}:\n(.*?)(?=^  \S|\Z)', lock)
    if not entry or f'version: "{version}"' not in entry[1]:
        raise ValueError(f'Review the tvOS source recipe when upgrading package:{name}')
    config = root / '.dart_tool/package_config.json'
    matches = [item for item in json.loads(config.read_text())['packages'] if item['name'] == name]
    if len(matches) != 1:
        raise ValueError(f'Exactly one resolved {name} package is required')
    uri = urlparse(matches[0]['rootUri'])
    if uri.netloc:
        raise ValueError('SQLite package cannot resolve to a remote file authority')
    if uri.scheme == 'file':
        package = Path(unquote(uri.path))
    elif uri.scheme:
        raise ValueError('SQLite package must be resolved locally')
    else:
        package = (config.parent / unquote(uri.path)).resolve()
    return package


def sqlite_package(root: Path, version: str) -> Path:
    package = resolved_package(root, 'sqlite3', version)
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
        raise ValueError(f'Native asset architecture mismatch: {binary}')
    expected = '8' if platform == 'appletvsimulator' else '3'
    platforms = re.findall(r'^\s*platform\s+(\d+)\s*$', run('xcrun', 'otool', '-arch', 'all', '-l', str(binary)), re.M)
    if not platforms or set(platforms) != {expected}:
        raise ValueError(f'Native asset must contain genuine tvOS platform load commands: {binary}')
    exports = {line.split()[-1].removeprefix('_') for line in run('xcrun', 'nm', '-gU', str(binary)).splitlines() if line.split()}
    if missing := symbols - exports:
        raise ValueError(f'Native asset is missing Dart FFI symbols: {sorted(missing)}')


def finish_framework(template: Path, scratch: Path, output_dir: Path, binaries: list[Path],
                     platform: str, architectures: list[str], minimum: str, symbols: set[str], receipt: dict) -> None:
    name = template.stem
    framework = scratch / template.name
    shutil.copytree(template, framework)
    shutil.rmtree(framework / '_CodeSignature', ignore_errors=True)
    executable = framework / name
    executable.chmod(0o755)
    if len(binaries) == 1:
        shutil.copyfile(binaries[0], executable)
    else:
        subprocess.run(['xcrun', 'lipo', '-create', *map(str, binaries), '-output', str(executable)], check=True)
    validate_binary(executable, platform, architectures, symbols)
    plist = framework / 'Info.plist'
    metadata = plistlib.loads(plist.read_bytes())
    metadata.update(CFBundleExecutable=name, MinimumOSVersion=minimum,
                    CFBundleSupportedPlatforms=['AppleTVSimulator' if platform == 'appletvsimulator' else 'AppleTVOS'],
                    DTPlatformName=platform)
    for key in ('DTSDKName', 'DTPlatformVersion', 'DTPlatformBuild', 'DTSDKBuild'):
        metadata.pop(key, None)
    plist.chmod(0o644)
    plist.write_bytes(plistlib.dumps(metadata))
    destination = output_dir / template.name
    if destination.is_symlink():
        raise ValueError('Refusing linked native asset destination')
    if destination.exists():
        shutil.rmtree(destination)
    receipt = receipt | {'platform': platform, 'architectures': architectures, 'minimumOSVersion': minimum,
                         'unsignedBinarySha256': digest(executable)}
    (framework / 'pleazyng-source.json').write_text(json.dumps(receipt, indent=2) + '\n')
    framework.rename(destination)
    (output_dir / f'{name}-build.json').write_text(json.dumps(receipt, indent=2) + '\n')


def objective_symbols(package: Path) -> set[str]:
    bindings = (package / 'lib/src/c_bindings_generated.dart').read_text()
    generated = (package / 'lib/src/objective_c_bindings_generated.dart').read_text()
    # Dart aliases and class getters can explicitly name a different C symbol.
    # A Dart escaped dollar in OBJC_CLASS_\$_Foo denotes a literal dollar.
    symbols = {item.replace(r'\$', '$') for item in re.findall(r"symbol:\s*'([^']+)'", bindings + generated)}
    for annotation, name in re.findall(
        r'@ffi\.Native<.*?>\(([^;]*?)\)\s*external\s+[^;]*?\b([A-Za-z_]\w*)\s*\(', generated, re.S,
    ):
        if not re.search(r'\bsymbol\s*:', annotation):
            symbols.add(name)
    symbols.add('Dart_InitializeApiDL')
    return symbols


def stage_package_asset(root: Path, template: Path, output_dir: Path, platform: str,
                        architectures: list[str], minimum: str, sdk: str) -> None:
    name = template.stem
    pin = json.loads((root / 'tvos/native-asset-packages.lock.json').read_text())[name]
    package = resolved_package(root, pin['package'], pin['version'])
    lock = (root / 'pubspec.lock').read_text()
    entry = re.search(rf'(?ms)^  {re.escape(pin["package"])}:\n(.*?)(?=^  \S|\Z)', lock)
    archive_hash = re.search(r'sha256:\s*"?([0-9a-f]{64})', entry[1]) if entry else None
    if not archive_hash or archive_hash[1] != pin['archiveSha256']:
        raise ValueError(f'Native package archive differs from its reviewed pin: {name}')
    if digest(package / 'hook/build.dart') != pin['hookSha256']:
        raise ValueError(f'Review the changed native build recipe for {name}')
    if name == 'objective_c':
        # Match the locked package hook: its C API-DL implementation is one of
        # the recursively collected C sources; ObjC compilation requires ARC.
        sources = sorted(path for path in (package / 'src').rglob('*') if path.suffix in {'.c', '.m'})
        symbols = objective_symbols(package)
    else:
        sources = [package / 'src/pdfrx_pdfium_gate.c']
        symbols = set(re.findall(r"symbol:\s*'([^']+)'", (package / 'lib/src/pdfrx_pdfium_gate.dart').read_text()))
    if not sources or not symbols:
        raise ValueError(f'Missing sources or native bindings for {name}')
    with tempfile.TemporaryDirectory(prefix=f'.{name}-tvos-', dir=output_dir) as temporary:
        scratch = Path(temporary)
        binaries = []
        for arch in architectures:
            triple = f'{arch}-apple-tvos{minimum}' + ('-simulator' if platform == 'appletvsimulator' else '')
            common = ['xcrun', '--sdk', platform, 'clang', '-target', triple, '-isysroot', sdk]
            objects = []
            for index, source in enumerate(sources):
                obj = scratch / f'{arch}-{index}.o'
                flags = ['-x', 'objective-c', '-fobjc-arc'] if source.suffix == '.m' else []
                subprocess.run([*common, '-c', str(source), '-fPIC', '-gline-tables-only',
                                '-I', str(package / 'src'), *flags, '-o', str(obj)], check=True)
                objects.append(obj)
            binary = scratch / arch
            link = ['-Wl,-encryptable', '-undefined', 'dynamic_lookup'] if name == 'objective_c' else []
            subprocess.run([*common, '-dynamiclib', '-headerpad_max_install_names',
                            '-install_name', f'@rpath/{name}.framework/{name}',
                            *link, *map(str, objects), '-o', str(binary)], check=True)
            binaries.append(binary)
        source_files = sorted(path for path in (package / 'src').rglob('*') if path.suffix in {'.c', '.m', '.h'})
        receipt = pin | {'sourceFilesSha256': {str(path.relative_to(package)): digest(path) for path in source_files}}
        finish_framework(template, scratch, output_dir, binaries, platform, architectures, minimum, symbols, receipt)
        print(f'Built {name} from {pin["package"]} {pin["version"]} for {platform}: {architectures}')


def stage(root: Path, input_dir: Path, output_dir: Path, platform: str, architectures: list[str], minimum: str) -> None:
    if platform not in {'appletvos', 'appletvsimulator'} or not re.fullmatch(r'\d+(?:\.\d+){0,2}', minimum):
        raise ValueError('A real tvOS SDK and deployment target are required')
    if not architectures or any(arch not in {'arm64', 'x86_64'} for arch in architectures):
        raise ValueError('Unsupported tvOS native asset architecture')
    if platform == 'appletvos' and architectures != ['arm64']:
        raise ValueError('tvOS devices require arm64')
    frameworks = sorted(path.name for path in input_dir.glob('*.framework'))
    supported = {'sqlite3.framework', 'objective_c.framework', 'pdfrx_pdfium_gate.framework'}
    if 'sqlite3.framework' not in frameworks or set(frameworks) - supported:
        raise ValueError(f'Unported or missing tvOS native assets: {frameworks}')
    template = input_dir / 'sqlite3.framework'
    for name in frameworks:
        candidate = input_dir / name
        if candidate.is_symlink() or any(path.is_symlink() for path in candidate.rglob('*')):
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
        finish_framework(template, scratch, output_dir, binaries, platform, architectures, minimum,
                         symbols, pin | {'compileDefines': defines})
        print(f'Built SQLite {pin["sqliteVersion"]} for {platform}: {architectures}')
    for name in frameworks:
        if name != 'sqlite3.framework':
            stage_package_asset(root, input_dir / name, output_dir, platform, architectures, minimum, sdk)


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
