"""Receipt reuse must never admit modified files or escape the staged bundle."""
from pathlib import Path
from types import SimpleNamespace
import json
import os
from unittest import mock
import subprocess
import tempfile
import unittest

import build_runtime


class RustToolchainTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / 'rustup'
        self.bin = self.home / 'toolchains' / (build_runtime.RUST + '-aarch64-apple-darwin') / 'bin'
        self.bin.mkdir(parents=True)
        for name in ('rustc', 'rustdoc'):
            (self.bin / name).write_text('synthetic tool path fixture; not executable')
        self.env = {'RUSTUP_HOME': str(self.home), 'CARGO_HOME': str(self.root / 'cargo'),
                    'PATH': '/usr/bin:/bin', 'RUSTC': '/unrelated/rustc',
                    'RUSTDOC': '/unrelated/rustdoc', 'RUSTC_WRAPPER': '/unrelated/wrapper'}

    def selected_tool(self, command, **kwargs):
        self.assertEqual(command[:4], ['rustup', 'which', '--toolchain', build_runtime.RUST])
        self.assertIs(kwargs['env'], self.env)
        return str(self.bin / command[-1]) + '\n'

    def test_pinned_tools_override_host_selection_without_global_shims(self):
        with mock.patch.object(build_runtime.subprocess, 'check_output', side_effect=self.selected_tool):
            build_runtime.configure_rust_tools(self.env)
        self.assertEqual(self.env['RUSTC'], str(self.bin / 'rustc'))
        self.assertEqual(self.env['RUSTDOC'], str(self.bin / 'rustdoc'))
        self.assertEqual(self.env['PATH'].split(os.pathsep)[0], str(self.bin))
        self.assertNotIn('RUSTC_WRAPPER', self.env)
        self.assertEqual(self.env['RUSTUP_HOME'], str(self.home))
        self.assertEqual(self.env['CARGO_HOME'], str(self.root / 'cargo'))

    def test_missing_and_host_tools_are_rejected(self):
        host_tool = self.root / 'host/rustc'
        host_tool.parent.mkdir()
        host_tool.write_text('unrelated host compiler')
        for value, message in [(str(self.root / 'absent'), 'missing'),
                               (str(host_tool), 'escapes'), ('relative/rustc', 'missing')]:
            with self.subTest(value=value), mock.patch.object(
                    build_runtime.subprocess, 'check_output', return_value=value):
                with self.assertRaisesRegex(ValueError, message):
                    build_runtime.configure_rust_tools(self.env)

    def test_another_toolchain_version_is_rejected(self):
        other = self.home / 'toolchains/1.96.0-aarch64-apple-darwin/bin/rustc'
        other.parent.mkdir(parents=True)
        other.write_text('wrong compiler version fixture')
        with mock.patch.object(build_runtime.subprocess, 'check_output', return_value=str(other)):
            with self.assertRaisesRegex(ValueError, 'Unexpected pinned Rust tool path'):
                build_runtime.configure_rust_tools(self.env)

    def test_mixed_host_toolchains_are_rejected(self):
        other = self.home / 'toolchains' / (build_runtime.RUST + '-x86_64-apple-darwin') / 'bin/rustdoc'
        other.parent.mkdir(parents=True)
        other.write_text('other host tool fixture')
        with mock.patch.object(build_runtime.subprocess, 'check_output',
                               side_effect=[str(self.bin / 'rustc'), str(other)]):
            with self.assertRaisesRegex(ValueError, 'same toolchain'):
                build_runtime.configure_rust_tools(self.env)


class RuntimeOutputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        pin = self.root / 'native/visualizer/sources.lock.json'
        pin.parent.mkdir(parents=True)
        self.source = {
            'repository': 'https://github.com/snapetech-org/MilkRust.git',
            'commit': 'a' * 40,
            'ref': 'refs/pull/20/head',
        }
        pin.write_text(json.dumps({'milkrust': self.source}))
        self.output = self.root / 'DerivedSources/plezy-milkrust'
        self.args = SimpleNamespace(platform='ios-simulator', architectures='arm64',
                                    output=str(self.output), ndk=None)
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(build_runtime, 'ROOT', self.root).start()
        mock.patch.object(build_runtime, 'build_context',
                          return_value=('123', 'self-hosted', 'snapetech-org/pleazyng')).start()

    def write_receipt(self):
        self.output.mkdir(parents=True)
        library = self.output / 'libmilkrust_native.a'
        library.write_bytes(b'synthetic receipt fixture, not a runtime')
        receipt = {
            'sourceRevision': self.source['commit'], 'platform': self.args.platform,
            'architectures': ['arm64'], 'rustToolchain': build_runtime.RUST,
            'runId': '123', 'runnerPolicy': 'self-hosted',
            'repository': 'snapetech-org/pleazyng',
            'recipeSha256': build_runtime.digest(Path(build_runtime.__file__)),
            'files': {library.name: build_runtime.digest(library)},
        }
        (self.output / 'milkrust-build.json').write_text(json.dumps(receipt))
        return receipt

    def test_xcode_precreated_empty_output_starts_fresh_build(self):
        self.output.mkdir(parents=True)
        # Stop at the first source-fetch command: this regression checks output
        # admission without downloading or pretending to compile a runtime.
        with mock.patch.object(build_runtime, 'run', side_effect=RuntimeError('source fetch boundary')) as run:
            with self.assertRaisesRegex(RuntimeError, 'source fetch boundary'):
                build_runtime.build(self.args)
        self.assertEqual(run.call_args.args[:2], ('git', '-c'))
        self.assertFalse(self.output.exists())

    def test_preserves_unreceipted_files_and_directories(self):
        for name in ('libmilkrust_native.a', 'unknown-directory'):
            with self.subTest(name=name):
                self.output.mkdir(parents=True, exist_ok=True)
                entry = self.output / name
                if name.endswith('directory'):
                    entry.mkdir()
                else:
                    entry.write_bytes(b'unknown existing output')
                with mock.patch.object(build_runtime, 'run') as run:
                    with self.assertRaisesRegex(ValueError, 'without a valid receipt'):
                        build_runtime.build(self.args)
                    run.assert_not_called()
                self.assertTrue(entry.exists())
                if entry.is_dir():
                    entry.rmdir()
                else:
                    self.assertEqual(entry.read_bytes(), b'unknown existing output')
                    entry.unlink()

    def test_preserves_file_and_symlink_outputs(self):
        self.output.parent.mkdir(parents=True)
        self.output.write_bytes(b'unknown output file')
        with mock.patch.object(build_runtime, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'without a valid receipt'):
                build_runtime.build(self.args)
            run.assert_not_called()
        self.assertEqual(self.output.read_bytes(), b'unknown output file')
        self.output.unlink()
        real = self.root / 'real-directory'
        real.mkdir()
        try:
            self.output.symlink_to(real, target_is_directory=True)
        except OSError:
            self.skipTest('Host does not permit symlinks')
        with mock.patch.object(build_runtime, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'must not be a symlink'):
                build_runtime.build(self.args)
            run.assert_not_called()
        self.assertTrue(self.output.is_symlink())
        self.assertTrue(real.is_dir())

    def test_exact_receipt_reuses_without_fetching_or_removing_output(self):
        self.write_receipt()
        with mock.patch.object(build_runtime, 'run') as run:
            build_runtime.build(self.args)
            run.assert_not_called()
        self.assertTrue((self.output / 'milkrust-build.json').is_file())

    def test_mismatched_receipt_and_modified_artifact_remain_rejected(self):
        receipt = self.write_receipt()
        path = self.output / 'milkrust-build.json'
        for field, value in [('platform', 'ios'), ('architectures', ['x64']),
                             ('runId', '124'), ('sourceRevision', 'b' * 40),
                             ('recipeSha256', '0' * 64)]:
            with self.subTest(field=field), mock.patch.object(build_runtime, 'run') as run:
                path.write_text(json.dumps(receipt | {field: value}))
                with self.assertRaisesRegex(ValueError, 'differs from this build'):
                    build_runtime.build(self.args)
                run.assert_not_called()
                self.assertTrue(path.is_file())
        path.write_text(json.dumps(receipt))
        library = self.output / 'libmilkrust_native.a'
        library.write_bytes(b'modified artifact')
        with mock.patch.object(build_runtime, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'differs from this build'):
                build_runtime.build(self.args)
            run.assert_not_called()
        self.assertEqual(library.read_bytes(), b'modified artifact')


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
                   "GITHUB_REPOSITORY": "snapetech-org/pleazyng", "RUNNER_ENVIRONMENT": runner}
            self.assertEqual(build_runtime.build_context(env), ("123", runner, "snapetech-org/pleazyng"))
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
