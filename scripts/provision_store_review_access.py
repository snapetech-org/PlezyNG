#!/usr/bin/env python3
"""Create Android store-review access without exposing the signing key.

Requires Python cryptography and authenticated gh. The owner-only output is a
review instruction credential, never a store purchase or customer license.
Existing public keys are never rotated by this tool.
"""

import argparse
import base64
import json
import os
import subprocess
import time
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default='snapetech-org/pleazyng')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--emit-code', action='store_true', help='Emit the NEW grant to a trusted console-entry consumer; never use in CI logs')
    args = parser.parse_args()
    existing = subprocess.run(
        ['gh', 'variable', 'list', '--repo', args.repo, '--json', 'name'],
        check=True, capture_output=True, text=True,
    )
    if any(item['name'] == 'REVIEW_ACCESS_PUBLIC_KEY' for item in json.loads(existing.stdout)):
        parser.error('Review key already configured; reuse its issuer rather than rotate existing grants.')
    # Exclusive create before mutating GitHub; never overwrite an owner file.
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        key = Ed25519PrivateKey.generate()
        encode = lambda value: base64.urlsafe_b64encode(value).decode().rstrip('=')
        private = key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
        public = encode(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw))
        payload = json.dumps({
            'purpose': 'store-review', 'package': 'org.snapetech.pleazyng',
            'expires': int(time.time()) + 365 * 86400,
        }, separators=(',', ':')).encode()
        token = encode(payload) + '.' + encode(key.sign(payload))
        for name, value in [('REVIEW_ACCESS_SIGNING_KEY', encode(private)), ('STORE_REVIEW_ACCESS_CODE', token)]:
            subprocess.run(['gh', 'secret', 'set', name, '--repo', args.repo], input=value, text=True, check=True, capture_output=True)
        subprocess.run(['gh', 'variable', 'set', 'REVIEW_ACCESS_PUBLIC_KEY', '--repo', args.repo, '--body', public], check=True, capture_output=True)
        with os.fdopen(fd, 'w') as output:
            fd = None
            output.write('Android store-review code (valid one year; not a purchase):\n' + token + '\n')
        if args.emit_code:
            print(token)
        else:
            print(f'Configured public verification key and issuer secrets. Owner-only review credential: {args.output}')
    finally:
        if fd is not None:
            os.close(fd)


if __name__ == '__main__':
    main()
