"""Reject stale, corrupted, incomplete, or host-architecture SDK payloads."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/motion/prepare_android_samsung_litert_runtime.py'
SPEC = importlib.util.spec_from_file_location('samsung_runtime', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
PINS, REQUIRED, cache_valid = MODULE.PINS, MODULE.REQUIRED, MODULE.cache_valid


class SamsungPackageTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.elf = b'\x7fELF\x02\x01' + b'\x00' * 12 + b'\xb7\x00' + b'payload'
        for name in REQUIRED:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(self.elf if name.endswith('.so') else b'original licensing')
        self.receipt = {'inputs': PINS.copy(), 'files': {
            name: hashlib.sha256((self.root / name).read_bytes()).hexdigest() for name in REQUIRED}}
        self.save()

    def save(self):
        (self.root / 'source.json').write_text(json.dumps(self.receipt))

    def test_complete_pinned_payload_is_reused(self):
        self.assertTrue(cache_valid(self.root))

    def test_modified_provider_is_rebuilt(self):
        (self.root / REQUIRED[0]).write_bytes(b'corrupt')
        self.assertFalse(cache_valid(self.root))

    def test_changed_sdk_pin_is_rebuilt(self):
        self.receipt['inputs']['sdkSha256'] = '0' * 64
        self.save()
        self.assertFalse(cache_valid(self.root))

    def test_missing_dispatch_provider_is_rebuilt(self):
        del self.receipt['files'][REQUIRED[1]]
        self.save()
        self.assertFalse(cache_valid(self.root))

    def test_host_binary_cannot_satisfy_android_receipt(self):
        binary = self.elf[:18] + b'\x3e\x00' + self.elf[20:]
        (self.root / REQUIRED[0]).write_bytes(binary)
        self.receipt['files'][REQUIRED[0]] = hashlib.sha256(binary).hexdigest()
        self.save()
        self.assertFalse(cache_valid(self.root))

    def test_receipt_cannot_read_outside_output(self):
        self.receipt['files']['../outside'] = '0' * 64
        self.save()
        self.assertFalse(cache_valid(self.root))


if __name__ == '__main__':
    unittest.main()
