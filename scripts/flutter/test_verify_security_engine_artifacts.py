"""Small structural PE fixtures; these are not native engine qualification."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import stat
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from build_security_engine import VERSION, FRAMEWORK, ENGINE, DART, SKIA, PATCHES, DEPOT
from verify_security_engine_artifacts import verify


def pe(machine):
    image = bytearray(512)
    image[:2] = b'MZ'
    struct.pack_into('<I', image, 0x3C, 128)
    image[128:132] = b'PE\0\0'
    struct.pack_into('<HH', image, 132, machine, 1)
    struct.pack_into('<HH', image, 148, 112, 0x2002)
    struct.pack_into('<H', image, 152, 0x20B)
    return bytes(image)


class SecurityEngineAssetsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for arch in ('x64', 'arm64'):
            self.write(arch)

    def digest(self, archive):
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        archive.with_name(archive.name + '.sha256').write_text(f'{digest}  {archive.name}\n')

    def write(self, arch='x64', *, change=None, extra=None, provenance=None):
        directory = self.root / f'flutter-security-engine-{arch}'
        directory.mkdir(exist_ok=True)
        archive = directory / f'flutter-pleazyng-windows-{VERSION}-{arch}.zip'
        receipt = {
            'frameworkVersion': VERSION, 'frameworkRevision': FRAMEWORK,
            'engineRevision': ENGINE, 'dartRevision': DART, 'skiaRevision': SKIA,
            'patchRevision': PATCHES, 'depotRevision': DEPOT,
            'patchSource': 'https://github.com/edde746/flutter-plezy',
            'architecture': arch, 'advisory': 'GHSA-frr6-h895-5pxp',
        }
        receipt.update(provenance or {})
        entries = {f'windows-{arch}{suffix}/flutter_windows.dll': pe(0x8664 if arch == 'x64' else 0xAA64)
                   for suffix in ('', '-release')}
        entries.update({'LICENSE.flutter-plezy': b'license fixture',
                        'pleazyng-engine-provenance.json': json.dumps(receipt).encode()})
        if change:
            change(entries)
        with zipfile.ZipFile(archive, 'w') as output:
            for name, data in entries.items():
                output.writestr(name, data)
            for name, data in extra or []:
                output.writestr(name, data)
        self.digest(archive)
        return archive

    def verify(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return verify(self.root)

    def test_two_archives_require_exact_provenance_and_digests(self):
        self.assertEqual(len(self.verify()), 4)
        archive = self.root / f'flutter-security-engine-arm64/flutter-pleazyng-windows-{VERSION}-arm64.zip'
        archive.write_bytes(archive.read_bytes() + b'tampered')
        with self.assertRaisesRegex(ValueError, 'digest mismatch'):
            self.verify()

    def test_machine_identity_is_checked_for_debug_and_release(self):
        for suffix in ('', '-release'):
            with self.subTest(suffix=suffix):
                self.write(change=lambda entries: entries.update({f'windows-x64{suffix}/flutter_windows.dll': pe(0xAA64)}))
                with self.assertRaisesRegex(ValueError, 'architecture mismatch'):
                    self.verify()

    def test_malformed_or_non_dll_pe_headers_are_rejected(self):
        for offset, value in [(0, b'XX'), (0x3C, struct.pack('<I', 0x1000000)),
                              (128, b'NOPE'), (148, struct.pack('<HH', 112, 2)), (152, b'\x0b\x01')]:
            with self.subTest(offset=offset):
                image = bytearray(pe(0x8664))
                image[offset:offset + len(value)] = value
                self.write(change=lambda entries: entries.update({'windows-x64/flutter_windows.dll': bytes(image)}))
                with self.assertRaisesRegex(ValueError, 'PE'):
                    self.verify()

    def test_windows_case_collisions_and_extraction_paths_are_rejected(self):
        for name in ['windows-x64/FLUTTER_WINDOWS.DLL', 'windows-x64/../outside.dll',
                     'windows-x64\\outside.dll', 'windows-x64/file:stream', 'windows-x64/con.txt',
                     'windows-x64/file.', 'windows-x64/file ', 'windows-x64//file',
                     'windows-x64/con .txt', 'windows-x64/COM¹.txt',
                     '/windows-x64/file', 'windows-arm64/other.dll', 'unknown-root/file']:
            with self.subTest(name=name):
                self.write(extra=[(name, b'x')])
                with self.assertRaises(ValueError):
                    self.verify()

    def test_symlinks_and_unsupported_compression_are_rejected(self):
        link = zipfile.ZipInfo('windows-x64/link')
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.write(extra=[(link, b'/outside')])
        with self.assertRaisesRegex(ValueError, 'non-regular'):
            self.verify()
        unsupported = zipfile.ZipInfo('windows-x64/other')
        unsupported.compress_type = zipfile.ZIP_BZIP2
        self.write(extra=[(unsupported, b'x')])
        with self.assertRaisesRegex(ValueError, 'unsupported archive encoding'):
            self.verify()

    def test_expanded_archive_and_provenance_are_bounded(self):
        with patch('verify_security_engine_artifacts.MAX_EXPANDED', 512):
            with self.assertRaisesRegex(ValueError, 'expanded archive'):
                self.verify()
        self.write(provenance={'padding': 'x' * 33000})
        with self.assertRaisesRegex(ValueError, 'oversized or empty provenance'):
            self.verify()

    def test_license_and_all_pinned_source_identities_are_required(self):
        self.write(change=lambda entries: entries.pop('LICENSE.flutter-plezy'))
        with self.assertRaisesRegex(ValueError, 'license missing'):
            self.verify()
        for key in ['depotRevision', 'patchSource', 'frameworkRevision', 'architecture']:
            with self.subTest(key=key):
                self.write(provenance={key: 'wrong'})
                with self.assertRaisesRegex(ValueError, 'provenance mismatch'):
                    self.verify()

    def test_crc_is_checked_even_when_the_outer_digest_matches(self):
        archive = self.write()
        with zipfile.ZipFile(archive) as built:
            item = built.getinfo('windows-x64/flutter_windows.dll')
        data = bytearray(archive.read_bytes())
        name_size, extra_size = struct.unpack_from('<HH', data, item.header_offset + 26)
        data[item.header_offset + 30 + name_size + extra_size + 400] ^= 1
        archive.write_bytes(data)
        self.digest(archive)
        with self.assertRaisesRegex(zipfile.BadZipFile, 'CRC'):
            self.verify()

    def test_digest_files_are_bounded_and_a_partial_pair_is_not_announced(self):
        archive = self.write()
        archive.with_name(archive.name + '.sha256').write_text('x' * 257)
        with self.assertRaisesRegex(ValueError, 'unsafe archive or digest'):
            self.verify()
        self.write()
        self.write('arm64', provenance={'architecture': 'x64'})
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaisesRegex(ValueError, 'provenance mismatch'):
            verify(self.root)
        self.assertEqual(output.getvalue(), '')

    def test_large_archives_are_streamed_instead_of_reading_whole_files(self):
        with patch.object(Path, 'read_bytes', side_effect=AssertionError('unbounded read')):
            self.assertEqual(len(self.verify()), 4)


if __name__ == '__main__':
    unittest.main()
