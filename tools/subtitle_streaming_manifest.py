#!/usr/bin/env python3
"""Describe an already obtained, licensed Sherpa Zipformer2 streaming pack.

No downloads, inference or activation. Keep the manifest beside its four files.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--language', required=True)
    for key in ('encoder', 'decoder', 'joiner', 'tokens'):
        parser.add_argument('--' + key, required=True)
    parser.add_argument('--output', default='plezy-streaming.json')
    args = parser.parse_args()
    if not re.fullmatch(r'[a-z]{2,3}(-[A-Za-z0-9]{2,8})*', args.language):
        parser.error('Use the model’s declared language code, such as en or zh.')
    directory = args.directory.resolve(strict=True)
    if not directory.is_dir():
        parser.error('Choose the model directory.')
    def member(name):
        if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,159}', name):
            parser.error('Use file names without directory components.')
        return directory / name
    output = member(args.output)
    files, total = {}, 0
    for key in ('encoder', 'decoder', 'joiner', 'tokens'):
        name = getattr(args, key)
        path = member(name)
        if path.is_symlink() or not path.is_file() or path == output:
            parser.error('Model members must be separate regular files.')
        before = path.stat()
        total += before.st_size
        if before.st_size <= 0 or total > 1024**3 or key == 'tokens' and before.st_size > 16 * 1024**2:
            parser.error('Model exceeds the 1 GiB total / 16 MiB tokens limit.')
        digest = hashlib.sha256()
        with path.open('rb') as source:
            while chunk := source.read(1024**2):
                digest.update(chunk)
        after = path.stat()
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            parser.error('Model changed while hashing.')
        files[key] = {'name': name, 'sha256': digest.hexdigest()}
    document = {'schema': 1, 'type': 'zipformer2-transducer', 'sampleRate': 16000,
                'language': args.language, 'files': files}
    # Exclusive creation preserves existing manifests and model files.
    with output.open('x', encoding='utf-8') as target:
        json.dump(document, target, ensure_ascii=False, indent=2)
        target.write('\n')
    print(output)


if __name__ == '__main__':
    main()
