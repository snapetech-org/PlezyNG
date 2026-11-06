#!/usr/bin/env python3
"""Verify the signed Amazon APK and record evidence without exposing signing keys."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile


def inspect_apk(apk: Path, build_tools: Path) -> dict:
    signature = subprocess.run(
        [str(build_tools / 'apksigner'), 'verify', '--verbose', '--print-certs', str(apk)],
        check=True, capture_output=True, text=True,
    ).stdout
    if re.search(r'CN=Android Debug', signature, re.IGNORECASE):
        raise ValueError('Fire TV store APK must not use an Android debug certificate')
    certificates = re.findall(r'Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]{64})', signature)
    if not certificates:
        raise ValueError('No verified APK signing certificate')
    badging = subprocess.run(
        [str(build_tools / 'aapt'), 'dump', 'badging', str(apk)],
        check=True, capture_output=True, text=True,
    ).stdout
    if not re.search(r"^package: name='org\.snapetech\.pleazyng' ", badging, re.MULTILINE):
        raise ValueError('Unexpected Fire TV package identity')
    if not re.search(r'^leanback-launchable-activity:', badging, re.MULTILINE):
        raise ValueError('Fire TV APK has no Leanback launcher entry')
    if re.search(r"^uses-feature: name='android.hardware.touchscreen'", badging, re.MULTILINE):
        raise ValueError('Fire TV APK must not require a touchscreen')
    with zipfile.ZipFile(apk) as archive:
        abis = sorted({name.split('/')[1] for name in archive.namelist()
                       if name.startswith('lib/') and name.endswith('/libflutter.so')})
        if not {'armeabi-v7a', 'arm64-v8a'}.issubset(abis):
            raise ValueError('Fire TV APK must include both ARMv7 and ARM64 Flutter runtimes')
        if 'assets/AppstoreAuthenticationKey.pem' not in archive.namelist():
            raise ValueError('Amazon Appstore authentication public key is missing')
    version = re.search(r"versionName='([^']+)'", badging)
    with apk.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {
        'schema_version': 1, 'artifact': apk.name,
        'sha256': digest,
        'size_bytes': apk.stat().st_size, 'package': 'org.snapetech.pleazyng',
        'version': version.group(1) if version else None,
        'signer_sha256': [digest.lower() for digest in certificates],
        'abis': abis, 'leanback_launcher': True, 'debug_certificate': False,
        'qualification': 'static APK verification; Fire TV device playback and IAP testing still required',
    }



def verify_receipt(apk: Path, receipt_path: Path) -> dict:
    receipt = json.loads(receipt_path.read_text())
    with apk.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    if (receipt.get('schema_version') != 1
            or receipt.get('artifact') != apk.name
            or receipt.get('sha256') != digest
            or receipt.get('size_bytes') != apk.stat().st_size
            or receipt.get('package') != 'org.snapetech.pleazyng'
            or receipt.get('leanback_launcher') is not True
            or receipt.get('debug_certificate') is not False
            or not {'armeabi-v7a', 'arm64-v8a'}.issubset(receipt.get('abis', []))
            or not receipt.get('signer_sha256')
            or not all(re.fullmatch(r'[0-9a-f]{64}', value) for value in receipt['signer_sha256'])):
        raise ValueError('Fire TV verification receipt does not match this signed release APK')
    return receipt


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--build-tools', type=Path)
    mode.add_argument('--receipt', type=Path, help='Check an attested build receipt against the downloaded APK')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.receipt:
        verify_receipt(args.apk, args.receipt)
    else:
        if not args.output:
            parser.error('--output is required when inspecting an APK')
        receipt = inspect_apk(args.apk, args.build_tools)
        args.output.write_text(json.dumps(receipt, indent=2) + '\n')
    print(f"Verified signed Fire TV APK: {args.apk.name}")


if __name__ == '__main__':
    main()
