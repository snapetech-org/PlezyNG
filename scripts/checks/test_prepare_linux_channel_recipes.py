"""Checksum input boundaries and release recipe handoff behavior."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import prepare_linux_channel_recipes as recipes


class RecipePreparationTests(unittest.TestCase):
    def manifest(self):
        return f"{'a' * 64}  pleazyng-linux-x64.tar.gz\n{'b' * 64}  pleazyng-linux-arm64.tar.gz\n"

    def test_rejects_missing_duplicate_invalid_and_placeholder_hashes(self):
        valid = self.manifest()
        for value in (
            valid.splitlines()[0],
            valid + valid.splitlines()[0],
            valid.replace('a' * 64, 'SKIP'),
            valid.replace('b' * 64, '0' * 64),
        ):
            with self.subTest(value=value), self.assertRaises(ValueError):
                recipes.release_hashes(value)

    def test_preparation_is_pinned_complete_and_never_claims_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checksums = root / 'SHA256SUMS.txt'
            checksums.write_text(self.manifest())
            output = root / 'handoff'
            recipes.prepare('v3.0.7', checksums, output)
            receipt = json.loads((output / 'preparation.json').read_text())
            self.assertEqual(receipt['state'], 'prepared-unqualified')
            self.assertFalse(receipt['published'])
            self.assertFalse(receipt['native_builds_verified'])
            for relative, digest in receipt['files'].items():
                self.assertEqual(recipes.hashlib.sha256((output / relative).read_bytes()).hexdigest(), digest)
            nix = (output / 'nix/pleazyng.nix').read_text()
            self.assertIn('aarch64-linux', nix)
            self.assertIn('"' + 'b' * 64 + '"', nix)
            for relative in ('nix/pleazyng.nix',):
                text = (output / relative).read_text()
                self.assertIn('/releases/download/v3.0.7/', text)
                self.assertNotIn('@@', text)
                self.assertNotIn('edde746', text)
            with self.assertRaises(FileExistsError):
                recipes.prepare('v3.0.7', checksums, output)

    def test_rejects_tag_injection_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for tag in ('v3.0.7/../bad', 'v3.0.7"; bad', 'v3.0.7-rc1', '3.0.7'):
                with self.assertRaises(ValueError):
                    recipes.prepare(tag, root / 'missing', root / 'output')
            self.assertFalse((root / 'output').exists())

    def test_cache_relocation_uses_runtime_path_and_verifies_staged_modules(self):
        helper = recipes.ROOT / 'linux/packaging/flatpak/relocate-caches.py'
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / 'bundle'
            parent = bundle / 'lib/gdk-pixbuf-2.0/2.10.0'
            modules = parent / 'loaders'
            modules.mkdir(parents=True)
            module = modules / 'libpixbufloader-png.so'
            module.touch()
            cache = parent / 'loaders.cache'
            cache.write_text('"/build/old/libpixbufloader-png.so"\n')
            subprocess.run([sys.executable, str(helper), str(bundle)], check=True)
            self.assertEqual(cache.read_text(), f'"{module}"\n')
            subprocess.run([sys.executable, str(helper), str(bundle),
                            '--runtime-prefix', '/usr/lib/pleazyng'], check=True)
            self.assertEqual(cache.read_text(), '"/usr/lib/pleazyng/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-png.so"\n')
            module.unlink()
            result = subprocess.run([sys.executable, str(helper), str(bundle)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
