import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from build_security_engine import VERSION, FRAMEWORK, ENGINE, DART, SKIA, PATCHES
from verify_security_engine_artifacts import verify


class SecurityEngineAssetsTest(unittest.TestCase):
    def test_two_archives_require_exact_provenance_and_digests(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for arch in ('x64', 'arm64'):
                directory = root / f'flutter-security-engine-{arch}'
                directory.mkdir()
                archive = directory / f'flutter-pleazyng-windows-{VERSION}-{arch}.zip'
                with zipfile.ZipFile(archive, 'w') as output:
                    for suffix in ('', '-release'):
                        output.writestr(f'windows-{arch}{suffix}/flutter_windows.dll', b'binary fixture')
                    output.writestr('pleazyng-engine-provenance.json', json.dumps({
                        'frameworkVersion': VERSION, 'frameworkRevision': FRAMEWORK,
                        'engineRevision': ENGINE, 'dartRevision': DART, 'skiaRevision': SKIA,
                        'patchRevision': PATCHES, 'architecture': arch,
                        'advisory': 'GHSA-frr6-h895-5pxp',
                    }))
                digest = hashlib.sha256(archive.read_bytes()).hexdigest()
                (directory / (archive.name + '.sha256')).write_text(f'{digest}  {archive.name}\n')
            self.assertEqual(len(verify(root)), 4)
            archive = root / f'flutter-security-engine-arm64/flutter-pleazyng-windows-{VERSION}-arm64.zip'
            archive.write_bytes(archive.read_bytes() + b'tampered')
            with self.assertRaisesRegex(ValueError, 'digest mismatch'):
                verify(root)


if __name__ == '__main__':
    unittest.main()
