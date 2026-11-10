#!/usr/bin/env python3
"""Reject mismatched AppImage updates while preserving immutable legacy assets."""
import hashlib
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_appimage_update import verify


class AppImageUpdateTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='pleazyng-appimage-contract-')
        self.addCleanup(self.scratch.cleanup)
        self.image = Path(self.scratch.name) / 'pleazyng-linux-x86_64.AppImage'
        self.image.write_bytes(b'original immutable image')
        self.sidecar = Path(str(self.image) + '.zsync')
        self.information = 'gh-releases-zsync|snapetech-org|pleazyng|latest|' + self.sidecar.name
        self.header = {
            'zsync': '0.6.2', 'Filename': self.image.name, 'URL': self.image.name,
            'Blocksize': '2048', 'Hash-Lengths': '2,2,4',
            'Length': str(self.image.stat().st_size),
            'SHA-1': hashlib.sha1(self.image.read_bytes(), usedforsecurity=False).hexdigest(),
        }
        self.write_header()

    def write_header(self):
        self.sidecar.write_bytes(('\n'.join(f'{key}: {value}' for key, value in self.header.items()) + '\n\n').encode() + b'blocks')

    def test_matching_pair_is_accepted_without_mutating_image(self):
        before = self.image.read_bytes()
        self.assertEqual(verify(self.image, 'snapetech-org/pleazyng', self.information)['sidecar'], self.sidecar.name)
        self.assertEqual(self.image.read_bytes(), before)

    def test_same_size_image_corruption_is_rejected(self):
        self.image.write_bytes(b'X' + self.image.read_bytes()[1:])
        with self.assertRaisesRegex(ValueError, 'digest'):
            verify(self.image, 'snapetech-org/pleazyng', self.information)

    def test_wrong_filename_url_and_size_are_rejected(self):
        for field, value in [('Filename', 'other.AppImage'), ('URL', 'https://elsewhere/image'), ('Length', '1')]:
            with self.subTest(field=field):
                old = self.header[field]
                self.header[field] = value
                self.write_header()
                with self.assertRaises(ValueError):
                    verify(self.image, 'snapetech-org/pleazyng', self.information)
                self.header[field] = old

    def test_foreign_repository_cannot_be_an_update_source(self):
        with self.assertRaisesRegex(ValueError, 'repository'):
            verify(self.image, 'snapetech-org/pleazyng', self.information.replace('snapetech-org|pleazyng', 'other|app'))

    def test_legacy_images_remain_qualified_only_without_a_sidecar(self):
        with self.assertRaises(ValueError):
            verify(self.image, 'snapetech-org/pleazyng', None, allow_legacy=True)
        self.sidecar.unlink()
        self.assertEqual(verify(self.image, 'snapetech-org/pleazyng', None, allow_legacy=True)['contract'],
                         'legacy-without-update-information')
        with self.assertRaises(ValueError):
            verify(self.image, 'snapetech-org/pleazyng', None)

    def test_duplicate_header_fields_are_rejected(self):
        self.sidecar.write_bytes(self.sidecar.read_bytes().replace(b'\n\n', b'\nLength: 1\n\n', 1))
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            verify(self.image, 'snapetech-org/pleazyng', self.information)

    def test_truncated_control_blocks_are_rejected(self):
        self.sidecar.write_bytes(self.sidecar.read_bytes()[:-1])
        with self.assertRaisesRegex(ValueError, 'block checksums'):
            verify(self.image, 'snapetech-org/pleazyng', self.information)

    def test_release_sha256_manifest_covers_the_image_and_update_control_file(self):
        script = Path(__file__).resolve().parents[1] / 'create_release_checksums.py'
        subprocess.run([sys.executable, str(script), str(self.image.parent)], check=True, capture_output=True)
        lines = (self.image.parent / 'SHA256SUMS.txt').read_text().splitlines()
        actual = {name: digest for digest, name in (line.split('  ', 1) for line in lines)}
        self.assertEqual(actual, {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in (self.image, self.sidecar)})


if __name__ == '__main__':
    unittest.main()
