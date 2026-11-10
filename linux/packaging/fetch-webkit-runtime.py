#!/usr/bin/env python3
"""Download the pinned matching WebKit helper packages for release repackaging."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
sources = json.loads(Path(__file__).with_name('webkit-runtime.json').read_text())
for arch, source in sources.items():
    destination = args.output / f'webkit-{arch}.deb'
    if not destination.exists():
        partial = destination.with_suffix('.partial')
        with urllib.request.urlopen(source['url'], timeout=60) as response, partial.open('wb') as stream:
            while data := response.read(1024 * 1024):
                stream.write(data)
        partial.replace(destination)
    with destination.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != source['sha256']:
            raise ValueError(f'WebKit checksum mismatch: {arch}')
    print(f'Verified WebKit helper package: {arch}')
