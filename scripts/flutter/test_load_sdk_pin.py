import json
from pathlib import Path
import tempfile
import unittest

import load_sdk_pin as subject


class SDKPinTest(unittest.TestCase):
    def test_canonical_manifest_is_valid(self):
        self.assertEqual(set(subject.load()), {'schemaVersion', 'version', 'frameworkRevision', 'engineRevision'})

    def test_invalid_and_environment_injection_values_fail(self):
        pin = subject.load()
        for key, value in [('version', '3.47.8\nINJECTED=1'), ('version', 'stable'),
                           ('schemaVersion', True), ('frameworkRevision', 'main'),
                           ('engineRevision', 'a' * 39), ('version', None)]:
            with self.subTest(key=key, value=value), tempfile.TemporaryDirectory() as root:
                path = Path(root) / 'pin.json'
                path.write_text(json.dumps(dict(pin, **{key: value})))
                with self.assertRaises(ValueError):
                    subject.load(path)
