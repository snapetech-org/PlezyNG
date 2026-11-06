from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_firetv_apk import inspect_apk


class FireTVAPKTest(unittest.TestCase):
    def inspect(self, *, debug=False, tv=True, abis=('armeabi-v7a', 'arm64-v8a'), key=True):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / 'app.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                for abi in abis:
                    archive.writestr(f'lib/{abi}/libflutter.so', b'fixture')
                if key:
                    archive.writestr('assets/AppstoreAuthenticationKey.pem', 'public key fixture')
            signature = 'Signer #1 certificate SHA-256 digest: ' + 'a' * 64
            if debug:
                signature += '\nSigner #1 certificate DN: CN=Android Debug, O=Android, C=US'
            badging = "package: name='org.snapetech.pleazyng' versionName='3.0.0'\n"
            if tv:
                badging += "leanback-launchable-activity: name='org.snapetech.pleazyng.Launcher'\n"
            with patch('verify_firetv_apk.subprocess.run', side_effect=[
                subprocess.CompletedProcess([], 0, signature, ''),
                subprocess.CompletedProcess([], 0, badging, ''),
            ]):
                return inspect_apk(apk, Path('/fixture/build-tools'))

    def test_signed_tv_apk_records_certificate_and_both_arm_abis(self):
        receipt = self.inspect()
        self.assertEqual(receipt['signer_sha256'], ['a' * 64])
        self.assertEqual(receipt['abis'], ['arm64-v8a', 'armeabi-v7a'])
        self.assertEqual(len(receipt['sha256']), 64)

    def test_debug_signing_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'debug certificate'):
            self.inspect(debug=True)

    def test_phone_only_launcher_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Leanback'):
            self.inspect(tv=False)

    def test_missing_stick_abi_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'ARMv7 and ARM64'):
            self.inspect(abis=('arm64-v8a',))

    def test_missing_amazon_key_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'public key'):
            self.inspect(key=False)

    def test_failed_signature_verification_propagates(self):
        with patch('verify_firetv_apk.subprocess.run', side_effect=subprocess.CalledProcessError(1, 'apksigner')):
            with self.assertRaises(subprocess.CalledProcessError):
                inspect_apk(Path('app.apk'), Path('/fixture'))


if __name__ == '__main__':
    unittest.main()
