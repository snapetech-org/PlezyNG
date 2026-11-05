#!/usr/bin/env python3
"""Build pinned libretro cores into an explicit package staging directory.

Run only on an authorized private build machine. No emulator/ROM downloads
happen in PlezyNG. Cross builds pass the toolchain's make variables verbatim as
individual argv entries; shell expansion is never used.
"""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys

PINS = {
    'gambatte': ('gambatte-libretro', '7809bb68ee96c3e6c74e9d9c4c8bb09aa7c6801d', 'Makefile'),
    'mgba': ('mgba', '7a12d6d4b9acb14c0ae62c9166b6a2f3d08007f6', None),
    'fceumm': ('libretro-fceumm', 'ac0d00a7fc01166f84c7bac01d1084ebfd2b865e', 'Makefile.libretro'),
    # These two upstreams have additional license restrictions. They are opt-in
    # packaging inputs, never part of the freely redistributable default set.
    'snes9x': ('snes9x', 'fae2fea08f74180759ef540ee94259213f503480', 'libretro/Makefile'),
    'genesis_plus_gx': ('Genesis-Plus-GX', '60bee4c724859710ce05672239e5b601ad01382e', 'Makefile.libretro'),
}

def run(args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=pathlib.Path, required=True)
    parser.add_argument('--stage', type=pathlib.Path, required=True)
    parser.add_argument('--core', action='append', choices=PINS)
    parser.add_argument('--platform', required=True, help='An upstream libretro make platform, e.g. unix, osx, android, ios-arm64')
    parser.add_argument('--make-var', action='append', default=[], help='KEY=value; cross compiler, arch and SDK flags')
    parser.add_argument('--cmake-arg', action='append', default=[], help='mGBA CMake definition, e.g. --cmake-arg=-DCMAKE_TOOLCHAIN_FILE=/path/to/toolchain.cmake')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--restricted-core-licenses-reviewed', action='store_true')
    args = parser.parse_args()
    cores = list(dict.fromkeys(args.core or ['gambatte', 'mgba', 'fceumm']))
    if any(c in {'snes9x', 'genesis_plus_gx'} for c in cores) and not args.restricted_core_licenses_reviewed:
        parser.error('Restricted cores require a separate distribution-license review before staging.')
    for value in args.make_var:
        if '=' not in value or not value.split('=', 1)[0].replace('_', '').isalnum():
            parser.error('make variables must use KEY=value')
    if any(not value.startswith('-D') or '=' not in value[2:] for value in args.cmake_arg):
        parser.error('CMake arguments must be individual -DKEY=value definitions')
    native_platforms = {'linux': {'unix', 'linux'}, 'darwin': {'osx'}, 'win32': {'win', 'windows'}}.get(sys.platform, set())
    if 'mgba' in cores and args.platform not in native_platforms and not any(
        value.startswith(('-DCMAKE_TOOLCHAIN_FILE=', '-DCMAKE_SYSTEM_NAME=', '-DCMAKE_OSX_SYSROOT=')) for value in args.cmake_arg
    ):
        parser.error('mGBA cross builds require an explicit CMake toolchain or target SDK; make variables do not configure CMake')
    args.source_root = args.source_root.resolve()
    args.stage = args.stage.resolve()
    args.source_root.mkdir(parents=True, exist_ok=True)
    args.stage.mkdir(parents=True, exist_ok=True)
    manifest = []
    for core in cores:
        repo, revision, makefile = PINS[core]
        root = args.source_root / core
        if not root.exists():
            run(['git', 'clone', f'https://github.com/libretro/{repo}.git', str(root)])
        # A dedicated source checkout: refuse to erase local modifications.
        if subprocess.check_output(['git', 'status', '--porcelain'], cwd=root).strip():
            raise RuntimeError(f'{root} is modified; use a clean source directory')
        run(['git', 'fetch', 'origin', revision], root)
        run(['git', 'checkout', '--detach', revision], root)
        run(['git', 'submodule', 'update', '--init', '--recursive'], root)
        jobs = str(max(1, min(args.jobs, 64)))
        if makefile is None:
            # This pinned mGBA revision removed Makefile.libretro. Keep build
            # caches separate for each target/toolchain and build only its core.
            identity = hashlib.sha256(json.dumps([revision, args.platform, args.cmake_arg]).encode()).hexdigest()[:20]
            output = args.source_root / '_build' / core / identity
            run(['cmake', '-S', str(root), '-B', str(output), '-DCMAKE_BUILD_TYPE=Release',
                 '-DBUILD_LIBRETRO=ON', '-DSKIP_LIBRARY=ON', '-DBUILD_QT=OFF', '-DBUILD_SDL=OFF',
                 '-DBUILD_TEST=OFF', '-DBUILD_SUITE=OFF', '-DDISABLE_DEPS=ON', *args.cmake_arg])
            run(['cmake', '--build', str(output), '--config', 'Release', '--target', 'mgba_libretro', '--parallel', jobs])
        else:
            make = root / makefile
            command = ['make', '-f', make.name, f'platform={args.platform}', *args.make_var]
            # Make does not track architecture/compiler flags in existing .o
            # files. Never reuse another ABI's objects in the next package.
            run([*command, 'clean'], make.parent)
            run([*command, '-j' + jobs], make.parent)
            output = root
        candidates = [p for p in output.rglob(f'{core}_libretro.*') if p.suffix in {'.so', '.dylib', '.dll'} and p.is_file()]
        if len(candidates) != 1:
            raise RuntimeError(f'Expected one {core} shared library, found {len(candidates)}')
        name = candidates[0].name
        if args.platform.startswith('android'):
            name = 'lib' + name
        shutil.copy2(candidates[0], args.stage / name)
        licenses = []
        tracked = subprocess.check_output(['git', 'ls-files', '--recurse-submodules', '-z'], cwd=root).decode().split('\0')
        for relative in tracked:
            source = root / relative
            if source.is_file() and source.name.upper().startswith(('LICENSE', 'COPYING', 'COPYRIGHT')):
                dest = args.stage / f'{core}-licenses' / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, dest); licenses.append(dest.relative_to(args.stage).as_posix())
        if not licenses:
            raise RuntimeError(f'No license copied for {core}; do not distribute this stage')
        manifest.append({'core': core, 'commit': revision, 'library': name,
                         'platform': args.platform, 'make_variables': args.make_var, 'cmake_arguments': args.cmake_arg if makefile is None else [],
                         'sha256': hashlib.sha256((args.stage / name).read_bytes()).hexdigest(), 'licenses': licenses})
    (args.stage / 'romm-cores.json').write_text(json.dumps(manifest, indent=2) + '\n')

if __name__ == '__main__':
    main()
