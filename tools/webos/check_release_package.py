#!/usr/bin/env python3
"""Verify the built webOS package and its actual application-source provenance."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re

from verify_package import expected_package_version, load_lock, verify_ipk


def verify(artifact: Path, source_commit: str, version: str) -> dict:
    if not re.fullmatch(r'[0-9a-f]{40}', source_commit):
        raise ValueError('source commit must be an exact Git SHA')
    if version != expected_package_version():
        raise ValueError('release version differs from pubspec.yaml')
    report = verify_ipk(artifact, load_lock())
    provenance = json.loads((artifact.parent / 'webos-app-provenance.json').read_text())
    if provenance.get('sourceCommit') != source_commit:
        raise ValueError('webOS application source differs from the release source')
    if provenance.get('version') != version:
        raise ValueError('webOS application provenance version differs from the release')
    if provenance.get('packageSha256') != report['packageSha256']:
        raise ValueError('webOS package differs from its recorded SHA-256')
    if provenance.get('package') != artifact.name:
        raise ValueError('webOS provenance names a different package')
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', type=Path, required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.artifact, args.source_commit, args.version), indent=2))


if __name__ == '__main__':
    main()
