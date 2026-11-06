#!/usr/bin/env python3
"""Capture an explicit Android device/AVD and record screenshot provenance."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True, help='Explicit adb serial; never selects another agent device')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--name', required=True, help='Capture name without extension')
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--apk', required=True, type=Path)
    parser.add_argument('--kind', required=True, choices=['android-tv-emulator', 'phone-emulator', 'tablet-emulator', 'fire-tv-device', 'android-device'])
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.name):
        parser.error('name must contain only letters, numbers, hyphens and underscores')
    if not re.fullmatch(r'[0-9a-f]{40}', args.source_sha):
        parser.error('source-sha must be the full APK source commit')
    args.output.mkdir(parents=True, exist_ok=True)
    image = args.output / (args.name + '.png')
    receipt = args.output / (args.name + '.json')
    if image.exists() or receipt.exists():
        parser.error('capture already exists; use a new name to preserve evidence')

    def shell(*command):
        return subprocess.run(['adb', '-s', args.serial, 'shell', *command], check=True,
                              capture_output=True, text=True).stdout.strip()

    resumed = shell('dumpsys', 'activity', 'activities')
    if not re.search(r'(?:mResumedActivity|topResumedActivity).*org\.snapetech\.pleazyng/', resumed):
        parser.error('Pleazyng must be the resumed activity before capture')
    png = subprocess.run(['adb', '-s', args.serial, 'exec-out', 'screencap', '-p'],
                         check=True, capture_output=True).stdout
    if png[:8] != b'\x89PNG\r\n\x1a\n':
        parser.error('adb returned an invalid PNG')
    width, height = struct.unpack('>II', png[16:24])
    if args.kind in ('android-tv-emulator', 'fire-tv-device') and (width, height) != (1920, 1080):
        parser.error('Amazon TV captures require a native 1920x1080 surface; do not stretch phone images')
    with args.apk.open('rb') as stream:
        apk_hash = hashlib.file_digest(stream, 'sha256').hexdigest()
    installed_path = shell('pm', 'path', 'org.snapetech.pleazyng').splitlines()
    base_paths = [path.removeprefix('package:') for path in installed_path if path.endswith('/base.apk')]
    if len(base_paths) != 1 or shell('sha256sum', base_paths[0]).split()[0] != apk_hash:
        parser.error('installed APK does not match the supplied build; refusing false provenance')
    evidence = {
        'schema_version': 1, 'capture': image.name, 'kind': args.kind,
        'source_sha': args.source_sha, 'apk_sha256': apk_hash,
        'capture_sha256': hashlib.sha256(png).hexdigest(), 'serial': args.serial,
        'dimensions': [width, height], 'density': shell('wm', 'density'),
        'manufacturer': shell('getprop', 'ro.product.manufacturer'),
        'model': shell('getprop', 'ro.product.model'),
        'sdk': shell('getprop', 'ro.build.version.sdk'),
        'command': ['adb', '-s', args.serial, 'exec-out', 'screencap', '-p'],
        'qualification': 'Actual app capture; emulator does not establish Fire OS hardware or IAP qualification',
    }
    image.write_bytes(png)
    receipt.write_text(json.dumps(evidence, indent=2) + '\n')
    print(image)


if __name__ == '__main__':
    main()
