#!/usr/bin/env python3
"""Build and verify the paid Windows payload separately from direct downloads."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import re
import subprocess
import sys

RECEIPT = 'pleazyng-microsoft-store-build.json'
REQUIRED = ('pleazyng.exe', 'data/app.so', 'in_app_purchase_msstore_plugin.dll')


def validate_product_id(product_id: str) -> None:
    if not re.fullmatch(r'[A-Z0-9]{12}', product_id):
        raise ValueError('Microsoft lifetime add-on needs its 12-character Partner Center Store ID')


def build_arguments(
    arch: str,
    product_id: str,
    *,
    discord_application_id: str = '',
) -> list[str]:
    validate_product_id(product_id)
    if arch not in ('x64', 'arm64'):
        raise ValueError('Microsoft Store builds require x64 or arm64')
    arguments = [
        'flutter', 'build', 'windows', '--release',
        '--dart-define=SUPPORTER_MODE=iap', '--dart-define=MSSTORE_BUILD=true',
        f'--dart-define=LIFETIME_UNLOCK_PRODUCT_ID={product_id}',
        f'--split-debug-info=debug-info/windows-store-{arch}',
    ]
    for name, value in (
        ('PLEAZYNG_DISCORD_APPLICATION_ID', discord_application_id),
    ):
        if value.strip():
            arguments.append(f'--dart-define={name}={value}')
    return arguments


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        checksum = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(chunk)
        return checksum.hexdigest()


def write_receipt(bundle: Path, arch: str, product_id: str) -> None:
    # Only called after the explicit IAP Flutter build succeeds. Hash the AOT
    # and native files so a later direct build cannot silently replace them.
    data = {
        'channel': 'microsoft-store', 'supporter_mode': 'iap', 'trial_days': 7,
        'product_id': product_id, 'architecture': arch,
        'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
        'sha256': {name: digest(bundle / name) for name in REQUIRED},
        'store_purchase_verified': False,
    }
    (bundle / RECEIPT).write_text(json.dumps(data, indent=2) + '\n')


def verify_payload(bundle: Path, product_id: str, arch: str) -> None:
    validate_product_id(product_id)
    data = json.loads((bundle / RECEIPT).read_text())
    if (data.get('channel'), data.get('supporter_mode'), data.get('trial_days'),
            data.get('product_id'), data.get('architecture')) != ('microsoft-store', 'iap', 7, product_id, arch):
        raise ValueError('MSIX requires the matching trial/IAP Store payload, not the unlocked direct build')
    for name in REQUIRED:
        if data.get('sha256', {}).get(name) != digest(bundle / name):
            raise ValueError(f'Microsoft Store payload changed after build: {name}')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', required=True, choices=('x64', 'arm64'))
    parser.add_argument('--product-id', default=os.environ.get('MSSTORE_LIFETIME_PRODUCT_ID', ''))
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    bundle = args.bundle or Path(f'build/windows/{args.arch}/runner/Release')
    if args.verify_only:
        verify_payload(bundle, args.product_id, args.arch)
        return
    command = build_arguments(
        args.arch,
        args.product_id,
        discord_application_id=os.environ.get('PLEAZYNG_DISCORD_APPLICATION_ID', ''),
    )
    # Current Flutter selects Windows architecture from its native host and
    # does not expose --target-platform for this command.
    host_arch = {'amd64': 'x64', 'x86_64': 'x64', 'arm64': 'arm64', 'aarch64': 'arm64'}.get(platform.machine().lower())
    if sys.platform != 'win32' or host_arch != args.arch:
        raise ValueError(f'Run the {args.arch} Store build on a native {args.arch} Windows worker')
    (bundle / RECEIPT).unlink(missing_ok=True)
    # Store builds intentionally omit direct-download updater defines.
    subprocess.run(command, check=True)
    write_receipt(bundle, args.arch, args.product_id)
    verify_payload(bundle, args.product_id, args.arch)


if __name__ == '__main__':
    main()
