#!/usr/bin/env python3
"""Exercise the shipped converter and authored FEL fixture without network access."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def verify(bundle: Path, fixtures: Path, output: Path):
    data = json.loads(fixtures.read_text())
    output.mkdir(parents=True, exist_ok=True)
    inputs = {}
    for label, entry in data['files'].items():
        raw = base64.b64decode(entry['base64'], validate=True)
        if hashlib.sha256(raw).hexdigest() != entry['sha256']:
            raise ValueError('authored fixture checksum mismatch')
        path = output / entry['name']
        path.write_bytes(raw)
        inputs[label] = path
    results = {}
    for target, codec, transfer in (('hdr10', 'hevc', 'smpte2084'), ('sdr', 'h264', 'bt709')):
        destination = output / (target + '.mkv')
        command = [bundle / 'plezyng-dv-convert', '--bl', inputs['bl'], '--el', inputs['el'],
                   '--fps', data['fps'], '--target', target, '--output', destination, '--execute']
        process = subprocess.run(list(map(str, command)), capture_output=True, text=True, timeout=90)
        (output / (target + '.log')).write_text(process.stdout + process.stderr)
        process.check_returncode()
        probe_environment = dict(os.environ, LD_LIBRARY_PATH=str(bundle / 'lib/runtime'))
        probe_environment.pop('LD_PRELOAD', None)
        result = subprocess.check_output([str(bundle / 'bin/ffprobe'), '-v', 'error', '-count_frames',
                                          '-show_streams', '-of', 'json', str(destination)], text=True,
                                         env=probe_environment)
        stream = json.loads(result)['streams'][0]
        if (stream['codec_name'] != codec or stream['color_transfer'] != transfer
                or int(stream['nb_read_frames']) != data['frames']):
            raise ValueError('packaged converter output codec/frame/color contract failed')
        results[target] = {'codec': codec, 'transfer': transfer, 'frames': int(stream['nb_read_frames']),
                           'sha256': hashlib.sha256(destination.read_bytes()).hexdigest()}
    report = {'schema_version': 1, 'exports': results, 'physical_output_qualified': False}
    (output / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, default=Path(__file__).with_name('testdata') / 'offline-export-fixture.json')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    verify(args.bundle, args.fixtures, args.output)
