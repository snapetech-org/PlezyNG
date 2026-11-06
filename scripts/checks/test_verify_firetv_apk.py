from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_firetv_apk import inspect_apk, verify_receipt, has_tv_launcher


MANIFEST = """E: manifest (line=1)
  E: application (line=2)
    E: activity (line=3)
      A: android:name(0x01010003)="com.edde746.plezy.PlezyActivity"
    E: activity-alias (line=4)
      A: android:name(0x01010003)="com.edde746.plezy.MainActivity"
      A: android:exported(0x01010010)=(type 0x12)0xffffffff
      A: android:targetActivity(0x01010202)="com.edde746.plezy.PlezyActivity"
      E: intent-filter (line=5)
        E: action (line=6)
          A: android:name(0x01010003)="android.intent.action.MAIN"
        E: category (line=7)
          A: android:name(0x01010003)="android.intent.category.LEANBACK_LAUNCHER"
"""


class CompiledManifestLauncherTest(unittest.TestCase):
    def test_activity_alias_counts_without_a_badging_summary(self):
        self.assertTrue(has_tv_launcher(MANIFEST))

    def test_disabled_alias_does_not_count(self):
        disabled = MANIFEST.replace('      A: android:exported', '      A: android:enabled(0x0101000e)=(type 0x12)0x0\n      A: android:exported')
        self.assertFalse(has_tv_launcher(disabled))

    def test_unexported_alias_does_not_count(self):
        self.assertFalse(has_tv_launcher(MANIFEST.replace('0xffffffff', '0x0')))

    def test_main_and_category_must_share_a_filter(self):
        separate = MANIFEST.replace('        E: category', '      E: intent-filter (line=7)\n        E: category')
        self.assertFalse(has_tv_launcher(separate))

    def test_disabled_target_activity_does_not_count(self):
        disabled = MANIFEST.replace('    E: activity-alias', '      A: android:enabled(0x0101000e)=(type 0x12)0x0\n    E: activity-alias')
        self.assertFalse(has_tv_launcher(disabled))

    def test_phone_launcher_does_not_count(self):
        self.assertFalse(has_tv_launcher(MANIFEST.replace('LEANBACK_LAUNCHER', 'LAUNCHER')))


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
            with patch('verify_firetv_apk.subprocess.run', side_effect=[
                subprocess.CompletedProcess([], 0, signature, ''),
                subprocess.CompletedProcess([], 0, badging, ''),
                subprocess.CompletedProcess([], 0, MANIFEST if tv else '', ''),
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


class FireTVReceiptTest(unittest.TestCase):
    def exercise(self, mutate=None):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / 'app.apk'
            apk.write_bytes(b'signed APK fixture')
            receipt = {
                'schema_version': 1, 'artifact': apk.name,
                'sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
                'size_bytes': apk.stat().st_size, 'package': 'org.snapetech.pleazyng',
                'leanback_launcher': True, 'debug_certificate': False,
                'abis': ['armeabi-v7a', 'arm64-v8a'], 'signer_sha256': ['a' * 64],
            }
            if mutate:
                mutate(receipt)
            path = Path(directory) / 'receipt.json'
            path.write_text(json.dumps(receipt))
            return verify_receipt(apk, path)

    def test_matching_receipt(self):
        self.assertEqual(self.exercise()['package'], 'org.snapetech.pleazyng')

    def test_tampered_apk_hash(self):
        with self.assertRaisesRegex(ValueError, 'does not match'):
            self.exercise(lambda receipt: receipt.update(sha256='b' * 64))

    def test_debug_receipt(self):
        with self.assertRaisesRegex(ValueError, 'does not match'):
            self.exercise(lambda receipt: receipt.update(debug_certificate=True))

    def test_old_package_receipt(self):
        with self.assertRaisesRegex(ValueError, 'does not match'):
            self.exercise(lambda receipt: receipt.update(package='org.snapetech.plezyng'))


if __name__ == '__main__':
    unittest.main()
