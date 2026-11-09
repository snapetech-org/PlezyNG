#!/usr/bin/env python3
"""Match Play's registered certificate to independently verified APK output."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def signing_digests(text):
    # SDK 37 prints the registered legacy signer as V3.0 Signer when the APK
    # also carries Android 37 hybrid signatures. Never accept the source stamp
    # certificate: that authenticates the distributor, not this app identity.
    return {value.lower().replace(':', '') for value in re.findall(
        r'^(?:Signer #[0-9]+|V3\.0 Signer): certificate SHA-256 digest: ([0-9a-fA-F:]+)$', text, re.M)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    path = args.directory / 'play-qualification.json'
    receipt = json.loads(path.read_text())
    for apk in receipt['apks']:
        binary = args.directory / apk['file']
        with binary.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != apk['sha256']:
                raise ValueError('Downloaded Play APK checksum changed')
        text = (args.directory / (apk['file'] + '.signing.txt')).read_text()
        expected = apk['expected_signing_certificate_sha256'].lower().replace(':', '')
        if expected not in signing_digests(text):
            raise ValueError('Play registered signing certificate mismatch')
        apk['signing_certificate_verified'] = True
    path.write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    main()
