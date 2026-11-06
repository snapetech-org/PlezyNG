#!/usr/bin/env python3
"""Package verified ADB captures into RGB store upload sets without resizing."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import zipfile
from PIL import Image

GROUPS = {
    'amazon-firetv': ({'android-tv-emulator', 'fire-tv-device'}, 3),
    'google-play-phone': ({'phone-emulator', 'android-device'}, 2),
    'google-play-tablet': ({'tablet-emulator'}, 2),
}


def package_captures(source: Path, output: Path, group: str) -> Path:
    kinds, minimum = GROUPS[group]
    captures = []
    for receipt_path in sorted(source.glob('*.json')):
        receipt = json.loads(receipt_path.read_text())
        if receipt.get('kind') not in kinds:
            continue
        name = receipt.get('capture', '')
        if not name or Path(name).name != name or not name.endswith('.png'):
            raise ValueError('Capture receipt has an invalid image path')
        image_path = source / name
        if hashlib.sha256(image_path.read_bytes()).hexdigest() != receipt.get('capture_sha256'):
            raise ValueError(f'Capture hash mismatch: {name}')
        with Image.open(image_path) as image:
            if list(image.size) != receipt.get('dimensions'):
                raise ValueError(f'Capture dimensions do not match receipt: {name}')
            if group == 'amazon-firetv' and image.size != (1920, 1080):
                raise ValueError('Amazon TV images must already be 1920x1080')
            if min(image.size) < 320 or max(image.size) > 3840 or max(image.size) > 2 * min(image.size):
                raise ValueError(f'Unsupported store screenshot dimensions: {image.size}')
            if 'A' in image.getbands() and image.getchannel('A').getextrema() != (255, 255):
                raise ValueError('A native screenshot must be opaque; no compositing is performed')
            captures.append((name, image.convert('RGB'), receipt))
    if not minimum <= len(captures) <= (10 if group == 'amazon-firetv' else 8):
        raise ValueError(f'{group} requires {minimum} to {10 if group == "amazon-firetv" else 8} distinct captures')
    if len({receipt['capture_sha256'] for _, _, receipt in captures}) != len(captures):
        raise ValueError('Duplicate images do not count as distinct screenshots')
    if len({(receipt['source_sha'], receipt['apk_sha256']) for _, _, receipt in captures}) != 1:
        raise ValueError('Do not mix different app builds in one screenshot set')
    output.mkdir(parents=True, exist_ok=True)
    directory = output / group
    directory.mkdir(exist_ok=False)
    exported = []
    for name, image, receipt in captures:
        destination = directory / name
        image.save(destination, format='PNG')
        image.close()
        exported.append({**receipt, 'export_sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
                         'export_format': '24-bit RGB PNG; pixels unchanged; alpha removed only after opacity check'})
    manifest = {'schema_version': 1, 'group': group, 'captures': exported,
                'qualification': 'Actual app captures; emulator images do not establish Fire OS hardware, playback or IAP qualification'}
    (directory / 'capture-provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
    archive_path = output / (group + '-screenshots.zip')
    with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(directory.iterdir()):
            archive.write(path, path.name)
    return archive_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--group', required=True, choices=GROUPS)
    args = parser.parse_args()
    print(package_captures(args.input, args.output, args.group))


if __name__ == '__main__':
    main()
