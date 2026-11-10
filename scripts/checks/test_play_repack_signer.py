#!/usr/bin/env python3
"""Exercise actual JAR authentication: correct signer, wrong signer and tampering."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


@unittest.skipUnless(os.environ.get('BUNDLETOOL_JAR'), 'Pinned bundletool is supplied by the store-repack job')
class PlayRepackSignerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='pleazyng-test-signer-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.tool = Path(os.environ['BUNDLETOOL_JAR']).resolve()
        assert hashlib.sha256(cls.tool.read_bytes()).hexdigest() == 'a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29'
        source = Path(__file__).parents[1] / 'stores' / 'ReversionPlayManifest.java'
        cls.run_tool(['javac', '-cp', str(cls.tool), '-d', str(cls.root), str(source)])
        cls.jar = cls.root / 'synthetic-qa-only.jar'
        with zipfile.ZipFile(cls.jar, 'w') as jar:
            for i in range(1001):
                jar.writestr(f'payload/{i}.txt', f'original-payload-{i}')
        cls.key = cls.root / 'synthetic-qa-only.jks'
        cls.run_tool(['keytool', '-genkeypair', '-alias', 'qa-only', '-keyalg', 'RSA', '-keysize', '2048',
                      '-validity', '1', '-dname', 'CN=Synthetic QA Only', '-keystore', str(cls.key),
                      '-storepass', 'qa-only-password', '-keypass', 'qa-only-password'])
        cls.run_tool(['jarsigner', '-keystore', str(cls.key), '-storepass', 'qa-only-password',
                      '-keypass', 'qa-only-password', str(cls.jar), 'qa-only'])
        cert = cls.run_tool(['keytool', '-exportcert', '-keystore', str(cls.key), '-storepass', 'qa-only-password', '-alias', 'qa-only']).stdout
        cls.signer = hashlib.sha256(cert).hexdigest()

    @staticmethod
    def run_tool(command, check=True):
        return subprocess.run(command, check=check, capture_output=True, timeout=60)

    def verify(self, path, signer):
        return self.run_tool(['java', '-cp', f'{self.root}:{self.tool}', 'ReversionPlayManifest',
                              'verify-signer', str(path), signer], check=False)

    def test_correct_signer_authenticates_every_entry(self):
        self.assertEqual(self.verify(self.jar, self.signer).returncode, 0)

    def test_different_certificate_rejected(self):
        self.assertNotEqual(self.verify(self.jar, '0' * 64).returncode, 0)

    def test_tampered_signed_payload_rejected(self):
        tampered = self.root / 'tampered.jar'
        with zipfile.ZipFile(self.jar) as source, zipfile.ZipFile(tampered, 'w') as target:
            for item in source.infolist():
                target.writestr(item, b'changed' if item.filename == 'payload/0.txt' else source.read(item))
        self.assertNotEqual(self.verify(tampered, self.signer).returncode, 0)

    def test_unsigned_added_payload_rejected(self):
        added = self.root / 'unsigned-extra.jar'
        shutil.copyfile(self.jar, added)
        with zipfile.ZipFile(added, 'a') as jar:
            jar.writestr('unsigned-extra.txt', 'not covered by original signature')
        self.assertNotEqual(self.verify(added, self.signer).returncode, 0)


if __name__ == '__main__':
    unittest.main()
