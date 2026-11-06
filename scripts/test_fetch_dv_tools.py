#!/usr/bin/env python3
"""Downloaded executables must match their pin, file manifest and target ABI."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tarfile
import tempfile
import unittest

import fetch_dv_tools as tools


class OfflineRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle = self.root / 'bundle'
        self.bundle.mkdir()
        files = {}
        header = bytearray(20)
        header[:6] = b'\x7fELF\x02\x01'
        struct.pack_into('<H', header, 18, 62)
        for name in tools.REQUIRED:
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(header if name.endswith('.so') or name == 'bin/python3.12' else b'#!/bin/sh\n')
            path.chmod(0o755)
            files[name] = tools.digest(path)
        self.report = {'architecture': 'x86_64', 'files': files,
                       'lock': json.loads((tools.ROOT / 'tools/dv-engine/offline.lock.json').read_text())}
        self.write_report()

    def write_report(self):
        (self.bundle / 'provenance.json').write_text(json.dumps(self.report))

    def test_manifest_detects_tampering_and_mixed_architectures(self):
        tools.verify(self.bundle, 'x86_64')
        binary = self.bundle / 'plugins/libfelbaker.so'
        raw = bytearray(binary.read_bytes())
        struct.pack_into('<H', raw, 18, 183)
        binary.write_bytes(raw)
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            tools.verify(self.bundle, 'x86_64')
        self.report['files']['plugins/libfelbaker.so'] = tools.digest(binary)
        self.write_report()
        with self.assertRaisesRegex(ValueError, 'wrong-architecture'):
            tools.verify(self.bundle, 'x86_64')

    def test_unrecorded_files_and_missing_dependencies_are_rejected(self):
        extra = self.bundle / 'unrecorded.py'
        extra.write_text('unexpected executable code')
        with self.assertRaisesRegex(ValueError, 'unrecorded'):
            tools.verify(self.bundle, 'x86_64')
        extra.unlink()
        del self.report['files']['bin/ffmpeg']
        self.write_report()
        with self.assertRaisesRegex(ValueError, 'missing required'):
            tools.verify(self.bundle, 'x86_64')

    def test_archive_identity_and_extraction_preserve_existing_data(self):
        plain = self.root / 'bundle.tar'
        with tarfile.open(plain, 'w') as archive:
            archive.add(self.bundle, arcname='.')
        archive = self.root / 'bundle.tar.zst'
        subprocess.run(['zstd', '-q', str(plain), '-o', str(archive)], check=True)
        destination = self.root / 'installed'
        with self.assertRaisesRegex(ValueError, 'archive checksum'):
            tools.install(archive, destination, {'checksum': '0' * 64}, 'x86_64')
        self.assertFalse(destination.exists())
        entry = {'asset': archive.name, 'checksum': tools.digest(archive)}
        tools.install(archive, destination, entry, 'x86_64')
        (destination / 'keep').write_text('user data')
        with self.assertRaisesRegex(ValueError, 'already exists'):
            tools.install(archive, destination, entry, 'x86_64')
        self.assertEqual((destination / 'keep').read_text(), 'user data')


if __name__ == '__main__':
    unittest.main()
