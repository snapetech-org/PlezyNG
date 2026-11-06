import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from scripts.build_microsoft_store import RECEIPT, REQUIRED, build_arguments, verify_payload, write_receipt


class MicrosoftStoreBuildTest(unittest.TestCase):
    def test_store_build_uses_iap_and_rejects_placeholder_product_names(self):
        for arch in ('x64', 'arm64'):
            command = build_arguments(arch, '9TESTPRODUCT')
            self.assertIn('--dart-define=SUPPORTER_MODE=iap', command)
            self.assertIn('--dart-define=LIFETIME_UNLOCK_PRODUCT_ID=9TESTPRODUCT', command)
            self.assertIn(f'--split-debug-info=debug-info/windows-store-{arch}', command)
            self.assertNotIn('--dart-define=SUPPORTER_MODE=unlocked', command)
        for product_id in ('', 'pleazyng_lifetime_unlock', '9TESTPRODUCT;evil'):
            with self.assertRaises(ValueError):
                build_arguments('x64', product_id)

    def test_missing_receipt_and_replaced_direct_payload_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory)
            for name in REQUIRED:
                file = bundle / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(b'store build')
            with self.assertRaises(FileNotFoundError):
                verify_payload(bundle, '9TESTPRODUCT', 'x64')
            with patch('scripts.build_microsoft_store.subprocess.check_output', return_value='a' * 40):
                write_receipt(bundle, 'x64', '9TESTPRODUCT')
            verify_payload(bundle, '9TESTPRODUCT', 'x64')
            for product, arch in [('9OTHERTARGET', 'x64'), ('9TESTPRODUCT', 'arm64')]:
                with self.assertRaises(ValueError):
                    verify_payload(bundle, product, arch)
            data = json.loads((bundle / RECEIPT).read_text())
            data['supporter_mode'] = 'unlocked'
            (bundle / RECEIPT).write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                verify_payload(bundle, '9TESTPRODUCT', 'x64')
            data['supporter_mode'] = 'iap'
            (bundle / RECEIPT).write_text(json.dumps(data))
            (bundle / 'data/app.so').write_bytes(b'free direct build')
            with self.assertRaises(ValueError):
                verify_payload(bundle, '9TESTPRODUCT', 'x64')


if __name__ == '__main__':
    unittest.main()
