"""Receipt reuse must never admit modified files or escape the staged bundle."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import build_runtime


class RuntimeReceiptTests(unittest.TestCase):
    def test_checkout_includes_runtime_source_without_unrelated_long_presets(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            original, source = root / 'original', root / 'checkout'
            original.mkdir()
            subprocess.run(['git', 'init', '-q', str(original)], check=True)
            for name in build_runtime.SOURCE_PATHS:
                path = original / name
                if name in ('crates', 'docs', 'tools'):
                    path = path / 'nested/source.txt'
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('runtime source: ' + name)
            long_preset = original / 'content' / ('x' * 90) / ('y' * 90) / ('z' * 90 + '.milk')
            long_preset.parent.mkdir(parents=True)
            long_preset.write_text('unrelated preset')
            subprocess.run(['git', '-C', str(original), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(original), '-c', 'user.name=Fixture',
                            '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], check=True)
            revision = subprocess.check_output(['git', '-C', str(original), 'rev-parse', 'HEAD'], text=True).strip()
            subprocess.run(['git', 'clone', '--quiet', '--no-checkout', str(original), str(source)], check=True)
            build_runtime.checkout_runtime_source(source, revision)
            for name in build_runtime.SOURCE_PATHS:
                path = source / name
                self.assertTrue(path.exists(), name)
                if path.is_dir():
                    self.assertTrue((path / 'nested/source.txt').is_file())
            self.assertFalse((source / 'content').exists())
            self.assertEqual(subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip(), revision)
            self.assertEqual(subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain']), b'')

    def test_hosted_private_and_local_build_contexts_are_distinct(self):
        self.assertEqual(build_runtime.build_context({}), ("local", "local", None))
        for runner in ("github-hosted", "self-hosted"):
            env = {"GITHUB_ACTIONS": "true", "GITHUB_RUN_ID": "123",
                   "GITHUB_REPOSITORY": "snapetech-org/PlezyNG", "RUNNER_ENVIRONMENT": runner}
            self.assertEqual(build_runtime.build_context(env), ("123", runner, "snapetech-org/PlezyNG"))
            for field, value in [("GITHUB_RUN_ID", "0"), ("GITHUB_RUN_ID", "../run"),
                                 ("GITHUB_REPOSITORY", "../repo"), ("RUNNER_ENVIRONMENT", "unknown")]:
                with self.assertRaises(ValueError):
                    build_runtime.build_context(env | {field: value})

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
