#!/usr/bin/env python3
"""Build pinned libretro cores into an explicit package staging directory.

Run only on an authorized private build machine. No emulator/ROM downloads
happen in PlezyNG. Cross builds pass the toolchain's make variables verbatim as
individual argv entries; shell expansion is never used.
"""
import argparse
import json
import pathlib
import shutil
import subprocess

PINS = {
    'gambatte': ('gambatte-libretro', '7809bb68ee96c3e6c74e9d9c4c8bb09aa7c6801d', 'Makefile'),
    'mgba': ('mgba', '7a12d6d4b9acb14c0ae62c9166b6a2f3d08007f6', 'Makefile.libretro'),
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
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--restricted-core-licenses-reviewed', action='store_true')
    args = parser.parse_args()
    cores = args.core or ['gambatte', 'mgba', 'fceumm']
    if any(c in {'snes9x', 'genesis_plus_gx'} for c in cores) and not args.restricted_core_licenses_reviewed:
        parser.error('Restricted cores require a separate distribution-license review before staging.')
    for value in args.make_var:
        if '=' not in value or not value.split('=', 1)[0].replace('_', '').isalnum():
            parser.error('make variables must use KEY=value')
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
        make = root / makefile
        run(['make', '-f', make.name, f'-j{max(1, min(args.jobs, 64))}', f'platform={args.platform}', *args.make_var], make.parent)
        candidates = [p for p in root.rglob(f'{core}_libretro.*') if p.suffix in {'.so', '.dylib', '.dll'}]
        if len(candidates) != 1:
            raise RuntimeError(f'Expected one {core} shared library, found {len(candidates)}')
        name = candidates[0].name
        if args.platform.startswith('android'):
            name = 'lib' + name
        shutil.copy2(candidates[0], args.stage / name)
        licenses = []
        for source in root.iterdir():
            if source.is_file() and source.name.upper().startswith(('LICENSE', 'COPYING')):
                dest = args.stage / f'{core}-{source.name}'
                shutil.copy2(source, dest); licenses.append(dest.name)
        if not licenses:
            raise RuntimeError(f'No license copied for {core}; do not distribute this stage')
        import hashlib
        manifest.append({'core': core, 'commit': revision, 'library': name,
                         'sha256': hashlib.sha256((args.stage / name).read_bytes()).hexdigest(), 'licenses': licenses})
    (args.stage / 'romm-cores.json').write_text(json.dumps(manifest, indent=2) + '\n')

if __name__ == '__main__':
    main()
