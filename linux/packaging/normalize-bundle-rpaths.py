#!/usr/bin/env python3
"""Replace builder-specific ELF search paths when repackaging a release bundle."""

import argparse
import os
from pathlib import Path
import subprocess


def is_dynamic_elf(path):
    with path.open('rb') as stream:
        header = stream.read(64)
        if header[:4] != b'\x7fELF' or len(header) < 64:
            return False
        order = 'little' if header[5] == 1 else 'big'
        if header[4] == 2:
            offset = int.from_bytes(header[32:40], order)
            size = int.from_bytes(header[54:56], order)
            count = int.from_bytes(header[56:58], order)
        elif header[4] == 1:
            offset = int.from_bytes(header[28:32], order)
            size = int.from_bytes(header[42:44], order)
            count = int.from_bytes(header[44:46], order)
        else:
            raise ValueError(f'Unsupported ELF class: {path}')
        if not size:
            return False
        for index in range(count):
            stream.seek(offset + index * size)
            if int.from_bytes(stream.read(4), order) == 2:  # PT_DYNAMIC
                return True
    return False


def normalize(bundle):
    bundle = bundle.resolve()
    library = bundle / 'lib'
    if not library.is_dir():
        raise ValueError(f'Missing bundled library directory: {library}')
    changed = 0
    for path in sorted(bundle.rglob('*')):
        if path.is_symlink() or not path.is_file() or not is_dynamic_elf(path):
            continue
        old = subprocess.check_output(['patchelf', '--print-rpath', str(path)], text=True).strip()
        paths = ['$ORIGIN']
        tool = bundle / 'tools/dv'
        runtime = tool / 'lib/runtime'
        if runtime.is_dir() and path.is_relative_to(tool):
            relative_runtime = os.path.relpath(runtime, path.parent)
            if relative_runtime != '.':
                paths.append(f'$ORIGIN/{relative_runtime}')
        relative = os.path.relpath(library, path.parent)
        if relative != '.':
            paths.append(f'$ORIGIN/{relative}')
        for entry in old.split(':'):
            entry = entry.replace('${ORIGIN}', '$ORIGIN')
            if entry.startswith('$ORIGIN/'):
                target = (path.parent / entry[len('$ORIGIN/'):]).resolve()
                if target.is_relative_to(bundle) and entry not in paths:
                    paths.append(entry)
        new = ':'.join(paths)
        if new != old:
            subprocess.run(['patchelf', '--set-rpath', new, str(path)], check=True)
            changed += 1
    return changed


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    args = parser.parse_args()
    print(f'Normalized {normalize(args.bundle)} ELF search paths.')
