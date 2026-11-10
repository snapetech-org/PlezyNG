#!/usr/bin/env python3
"""Reproduce the bundled ten-band AutoEq catalog from the pinned HeSuVi archive.

Download the URL below and pass its filename. Nothing is extracted to disk, and
the digest is checked before any data is consumed. See docs/plezyng/music/AUTOEQ.md.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import zipfile

ROOT = Path(__file__).resolve().parents[2]
REVISION = '7ae0f56d53074872b028649617a22bbb4232feb7'
SOURCE = f'https://raw.githubusercontent.com/jaakkopasanen/AutoEq/{REVISION}/results/hesuvi.zip'
SHA256 = '96cc6df6cad65523c120cfd263f2c42a32eeb8a14a82dbfda25f23699c50c00b'
FREQUENCIES = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]


def interpolate(text):
    points = [tuple(map(float, entry.split())) for entry in text.removeprefix('GraphicEQ:').strip().split(';')]
    if len(points) < 2 or any(len(point) != 2 for point in points):
        raise ValueError('Invalid frequency response')
    for index, (hz, gain) in enumerate(points):
        if not math.isfinite(hz) or not math.isfinite(gain) or not 10 <= hz <= 100000 or abs(gain) > 60:
            raise ValueError('Invalid response value')
        if index and hz <= points[index - 1][0]:
            raise ValueError('Unordered response')
    result = []
    for hz in FREQUENCIES:
        if hz <= points[0][0]:
            gain = points[0][1]
        elif hz >= points[-1][0]:
            gain = points[-1][1]
        else:
            upper = next(index for index, point in enumerate(points) if point[0] >= hz)
            a, b = points[upper - 1], points[upper]
            gain = a[1] + (b[1] - a[1]) * math.log(hz / a[0]) / math.log(b[0] / a[0])
        result.append(round(max(-12.0, min(12.0, gain)), 3))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    with args.archive.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != SHA256:
            raise ValueError('AutoEq archive digest does not match the pinned source')
    profiles_by_source = {}
    input_count = 0
    with zipfile.ZipFile(args.archive) as archive:
        entries = archive.infolist()
        if len(entries) > 20000 or sum(entry.file_size for entry in entries) > 128 * 1024 * 1024:
            raise ValueError('Archive exceeds its work budget')
        for entry in entries:
            if entry.is_dir():
                continue
            path = PurePosixPath(entry.filename)
            if len(path.parts) != 3 or path.parts[0] != 'eq' or path.suffix != '.txt' or entry.file_size > 64000:
                raise ValueError(f'Unexpected archive entry: {entry.filename}')
            text = archive.read(entry).decode('utf-8')
            if not text.startswith('GraphicEQ:'):
                raise ValueError('Unsupported profile')
            input_count += 1
            # The upstream ZIP has four duplicate paths with different curves.
            # Match ordinary ZIP extraction: the last occurrence owns its path.
            profiles_by_source[entry.filename] = {'name': f'{path.parts[1]} {path.stem}', 'source': entry.filename, 'bands': interpolate(text)}
    profiles = list(profiles_by_source.values())
    profiles.sort(key=lambda profile: (profile['name'].casefold(), profile['source']))
    document = {'version': 1, 'revision': REVISION, 'source': SOURCE, 'sha256': SHA256,
                'license': 'MIT', 'frequencies': FREQUENCIES, 'inputProfiles': input_count,
                'duplicatePolicy': 'last archive occurrence', 'profiles': profiles}
    encoded = json.dumps(document, ensure_ascii=False, separators=(',', ':')) + '\n'
    destination = ROOT / 'assets/music/autoeq.json'
    if args.check:
        if destination.read_text() != encoded:
            raise ValueError('Bundled AutoEq catalog is stale')
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(encoded)
    print(f'{len(profiles)} headphone profiles; {len(encoded.encode())} bytes; verified {SHA256}')


if __name__ == '__main__':
    main()
