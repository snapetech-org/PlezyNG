#!/usr/bin/env python3
"""Verify an AppImage's fork-specific update information and zsync sidecar."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def embedded_update_information(image: Path) -> str | None:
    # Inspect the ELF without executing the artifact or modifying its bytes.
    result = subprocess.run(['readelf', '-p', '.upd_info', str(image)],
                            text=True, capture_output=True, check=True)
    strings = []
    for line in result.stdout.splitlines():
        match = re.match(r'\s*\[\s*[0-9a-fA-F]+\]\s+(.+)', line)
        if match:
            strings.append(match[1].strip())
    if len(strings) > 1:
        raise ValueError('Ambiguous AppImage update information')
    return strings[0] if strings else None


def verify(image: Path, repository: str, information: str | None, *, allow_legacy: bool = False) -> dict:
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Repository must be owner/name')
    sidecar = Path(str(image) + '.zsync')
    if information is None and allow_legacy and not sidecar.exists():
        return {'image': image.name, 'contract': 'legacy-without-update-information'}
    owner, name = repository.split('/')
    expected = f'gh-releases-zsync|{owner}|{name}|latest|{image.name}.zsync'
    if information != expected:
        raise ValueError('AppImage update information does not match this repository and asset name')
    with sidecar.open('rb') as stream:
        data = stream.read(65536)
    if b'\n\n' not in data:
        raise ValueError('Missing or oversized zsync header')
    fields = {}
    for line in data.split(b'\n\n', 1)[0].decode('ascii').splitlines():
        key, value = line.split(': ', 1)
        if key in fields:
            raise ValueError('Duplicate zsync header field')
        fields[key] = value
    if fields.get('zsync') != '0.6.2':
        raise ValueError('Unsupported zsync control-file format')
    if fields.get('Filename') != image.name or fields.get('URL') != image.name:
        raise ValueError('zsync filename and download URL must match the release asset')
    if fields.get('Length') != str(image.stat().st_size):
        raise ValueError('zsync length does not match the AppImage')
    block_size = int(fields['Blocksize'])
    sequence, rolling_bytes, strong_bytes = map(int, fields['Hash-Lengths'].split(','))
    if block_size <= 0 or sequence <= 0 or not 1 <= rolling_bytes <= 4 or not 1 <= strong_bytes <= 16:
        raise ValueError('Invalid zsync block parameters')
    blocks = (image.stat().st_size + block_size - 1) // block_size
    header_size = len(data.split(b'\n\n', 1)[0]) + 2
    if sidecar.stat().st_size - header_size != blocks * (rolling_bytes + strong_bytes):
        raise ValueError('Truncated or unexpected zsync block checksums')
    # SHA-1 is mandated by zsync's wire format, not used as a security signature.
    digest = hashlib.sha1(usedforsecurity=False)
    with image.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    if fields.get('SHA-1') != digest.hexdigest():
        raise ValueError('zsync digest does not match the AppImage')
    return {'image': image.name, 'sidecar': sidecar.name, 'contract': expected}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--image', type=Path)
    source.add_argument('--directory', type=Path)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--allow-legacy', action='store_true',
                        help='Accept historical images with no update metadata and no sidecar')
    args = parser.parse_args()
    images = [args.image] if args.image else sorted(args.directory.rglob('*.AppImage'))
    if not images:
        parser.error('No AppImage artifacts found')
    for image in images:
        print(json.dumps(verify(image, args.repository, embedded_update_information(image),
                                allow_legacy=args.allow_legacy), sort_keys=True))


if __name__ == '__main__':
    main()
