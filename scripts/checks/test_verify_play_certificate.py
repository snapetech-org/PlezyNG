"""App signing identity must not be confused with Google's distributor stamp."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('play_cert', ROOT / 'scripts/stores/verify_play_certificate.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PlayCertificateTests(unittest.TestCase):
    def test_sdk36_and_sdk37_registered_signers_exclude_source_stamp_and_hybrid_key(self):
        digest = 'ab' * 32
        for prefix in ('Signer #1', 'V3.0 Signer'):
            with self.subTest(prefix=prefix):
                text = (f'{prefix}: certificate SHA-256 digest: {digest}\n'
                        f'Source Stamp Signer: certificate SHA-256 digest: {"cd" * 32}\n'
                        f'V3.2 Hybrid Classical Signer: (minSdkVersion=37) certificate SHA-256 digest: {"ef" * 32}\n')
                self.assertEqual(module.signing_digests(text), {digest})
        self.assertEqual(module.signing_digests(f'Source Stamp Signer: certificate SHA-256 digest: {digest}\n'), set())


if __name__ == '__main__':
    unittest.main()
