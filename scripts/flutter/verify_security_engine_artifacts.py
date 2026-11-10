#!/usr/bin/env python3
"""Validate pinned dual-architecture engine archives before release."""
import hashlib
import json
from pathlib import Path
import sys
import zipfile
from build_security_engine import VERSION, FRAMEWORK, ENGINE, DART, SKIA, PATCHES

def verify(root):
    assets = []
    for arch in ('x64', 'arm64'):
        directory = root / f'flutter-security-engine-{arch}'
        archive = directory / f'flutter-pleazyng-windows-{VERSION}-{arch}.zip'
        sidecar = archive.with_name(archive.name + '.sha256')
        if not archive.is_file() or not sidecar.is_file():
            raise ValueError(f'Missing {arch} engine archive or digest')
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if sidecar.read_text().strip() != f'{digest}  {archive.name}':
            raise ValueError(f'{arch}: digest mismatch')
        with zipfile.ZipFile(archive) as built:
            members = built.namelist()
            if len(members) != len(set(members)) or len(members) > 20000:
                raise ValueError(f'{arch}: invalid member list')
            for entry in built.infolist():
                name = entry.filename.replace('\\', '/')
                if name.startswith('/') or ':' in name or '..' in name.split('/') or entry.file_size > 800000000:
                    raise ValueError(f'{arch}: unsafe archive member')
            for suffix in ('', '-release'):
                if f'windows-{arch}{suffix}/flutter_windows.dll' not in members:
                    raise ValueError(f'{arch}: engine binary missing')
            provenance = json.loads(built.read('pleazyng-engine-provenance.json'))
            expected = {'frameworkVersion': VERSION, 'frameworkRevision': FRAMEWORK,
                        'engineRevision': ENGINE, 'dartRevision': DART, 'skiaRevision': SKIA,
                        'patchRevision': PATCHES, 'architecture': arch,
                        'advisory': 'GHSA-frr6-h895-5pxp'}
            if any(provenance.get(key) != value for key, value in expected.items()):
                raise ValueError(f'{arch}: provenance mismatch')
        print(f'VERIFIED_ENGINE {arch} {digest}')
        assets.extend((archive, sidecar))
    return assets

if __name__ == '__main__':
    try:
        verify(Path(sys.argv[1]))
    except (ValueError, OSError, KeyError, zipfile.BadZipFile) as error:
        raise SystemExit(str(error))
