import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("macos_receipts", Path(__file__).parents[1] / "apple/finalize_macos_runtime_receipts.py")
receipts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(receipts)


class MacosRuntimeReceiptTest(unittest.TestCase):
    def test_resigning_updates_embedded_hash_and_preserves_build_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Pleazyng.app"
            path = app / "Contents/Resources/playback-notices/luajit-runtime.json"
            library = app / "Contents/Frameworks/libplezy_luajit.dylib"
            path.parent.mkdir(parents=True)
            library.parent.mkdir(parents=True)
            original = {"schemaVersion": 1, "embeddedLibrarySha256": "build-signature",
                        "linkLibrarySha256": "link", "inputArchiveSha256": "archive",
                        "nativeLockSha256": "lock", "architectures": ["arm64", "x86_64"],
                        "buildCommand": ["clang", "-dynamiclib"]}
            path.write_text(json.dumps(original))
            library.write_bytes(b"newly signed runtime")
            result = receipts.finalize(app)
            self.assertEqual(result["embeddedLibrarySha256"], hashlib.sha256(library.read_bytes()).hexdigest())
            self.assertEqual(result["buildEmbeddedLibrarySha256"], "build-signature")
            for key in original.keys() - {"embeddedLibrarySha256"}:
                self.assertEqual(result[key], original[key])
            self.assertEqual(json.loads(path.read_text()), result)
            self.assertEqual(receipts.finalize(app), result)


if __name__ == "__main__":
    unittest.main()
