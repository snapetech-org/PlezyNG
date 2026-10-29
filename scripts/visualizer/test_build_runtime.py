"""Receipt reuse must never admit modified files or escape the staged bundle."""
from pathlib import Path
import tempfile
import unittest

import build_runtime


class RuntimeReceiptTests(unittest.TestCase):
    def test_rejects_modified_missing_or_escaping_files(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "bundle"
            output.mkdir()
            library = output / "libmilkrust_native.so"
            library.write_bytes(b"synthetic receipt fixture, not a runtime")
            sha = build_runtime.digest(library)
            self.assertTrue(build_runtime.valid_files(output, {library.name: sha}))
            for name in ["../libmilkrust_native.so", "/libmilkrust_native.so", "C:/runtime.dll", "a\\b", "./runtime.dll"]:
                self.assertFalse(build_runtime.valid_files(output, {name: sha}))
            library.write_bytes(b"changed")
            self.assertFalse(build_runtime.valid_files(output, {library.name: sha}))
            library.unlink()
            self.assertFalse(build_runtime.valid_files(output, {library.name: sha}))
            self.assertFalse(build_runtime.valid_files(output, {}))

    def test_rejects_symlinked_resources(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            resource = root / "source.tar.gz"
            resource.write_bytes(b"synthetic source")
            output = root / "bundle"
            output.mkdir()
            try:
                (output / resource.name).symlink_to(resource)
            except OSError:
                self.skipTest("Host does not permit symlinks")
            self.assertFalse(build_runtime.valid_files(output, {resource.name: build_runtime.digest(resource)}))


if __name__ == "__main__":
    unittest.main()
