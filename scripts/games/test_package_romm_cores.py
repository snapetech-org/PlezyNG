import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import package_romm_cores as package
import build_romm_apple as apple


class CorrespondingSourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sources, self.libraries, self.pins = {}, {}, {}
        for core in package.DEFAULT_CORES:
            source = self.root / core
            source.mkdir()
            subprocess.run(['git', 'init', '-q', str(source)], check=True)
            (source / 'LICENSE').write_text('Fixture license\n')
            (source / 'core.c').write_text('int core(void) { return 1; }\n')
            subprocess.run(['git', '-C', str(source), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(source), '-c', 'user.name=Fixture',
                            '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], check=True)
            revision = package.git(source, 'rev-parse', 'HEAD').decode().strip()
            self.pins[core] = dict(package.PINS[core], commit=revision)
            self.sources[core] = source
            library = self.root / (core + '.so')
            library.write_bytes(b'fixture library')
            self.libraries[core] = library
        self.output = self.root / 'notices'
        patcher = patch.object(package, 'PINS', self.pins)
        patcher.start()
        self.addCleanup(patcher.stop)

    def stage(self):
        return package.package(self.sources, self.libraries, self.output, 'Linux', 'x86_64')

    def test_source_archive_and_receipt_match_built_inputs(self):
        result = self.stage()
        self.assertFalse(result['qualified'])
        self.assertEqual({entry['core'] for entry in result['cores']}, package.DEFAULT_CORES)
        for entry in result['cores']:
            self.assertEqual(entry['sha256'], package.digest(self.libraries[entry['core']]))
            archive = self.output / entry['sourceArchive']
            self.assertEqual(entry['sourceSha256'], package.digest(archive))
            with tarfile.open(archive) as source:
                names = source.getnames()
                self.assertTrue(any(name.endswith('/core.c') for name in names))
                self.assertTrue(any(name.endswith('/LICENSE') for name in names))
            self.assertTrue(all((self.output / license).is_file() for license in entry['licenses']))

    def test_tampered_archive_is_regenerated(self):
        entry = self.stage()['cores'][0]
        archive = self.output / entry['sourceArchive']
        archive.write_bytes(b'not source')
        self.stage()
        self.assertEqual(package.digest(archive), entry['sourceSha256'])

    def test_modified_or_untracked_sources_fail_before_publication(self):
        core = next(iter(self.sources))
        source = self.sources[core]
        for filename in ('core.c', 'untracked.c'):
            with self.subTest(filename=filename):
                path = source / filename
                original = path.read_bytes() if path.exists() else None
                path.write_text('changed')
                with self.assertRaisesRegex(ValueError, 'Modified'):
                    self.stage()
                if original is None:
                    path.unlink()
                else:
                    path.write_bytes(original)
        self.assertFalse((self.output / 'romm-cores.json').exists())

    def test_missing_core_or_empty_binary_fails(self):
        core = next(iter(self.libraries))
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            package.package({}, self.libraries, self.output, 'Linux', 'x86_64')
        self.libraries[core].write_bytes(b'')
        with self.assertRaisesRegex(ValueError, 'empty'):
            self.stage()


class AppleCacheTests(unittest.TestCase):
    def test_xcode_library_paths_resolve_the_active_sdk(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for suffix in ('-appletvos', '-appletvsimulator', '-iphoneos', '-iphonesimulator', ''):
                with self.subTest(suffix=suffix), patch.dict(os.environ, {'EFFECTIVE_PLATFORM_NAME': suffix}):
                    libraries = {}
                    for core in package.DEFAULT_CORES:
                        library = root / ('Release' + suffix) / (core + '.framework') / core
                        library.parent.mkdir(parents=True, exist_ok=True)
                        library.write_bytes(b'built framework')
                        libraries[core] = library.resolve()
                    values = [f'{core}={root}/Release${{EFFECTIVE_PLATFORM_NAME}}/{core}.framework/{core}'
                              for core in package.DEFAULT_CORES]
                    self.assertEqual(package.parse_inputs(values), libraries)

    def test_xcode_placeholder_requires_an_available_valid_sdk_setting(self):
        values = [f'{core}=/Release${{EFFECTIVE_PLATFORM_NAME}}/{core}'
                  for core in package.DEFAULT_CORES]
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, 'EFFECTIVE_PLATFORM_NAME'):
                package.parse_inputs(values)
        with patch.dict(os.environ, {'EFFECTIVE_PLATFORM_NAME': '/../other'}):
            with self.assertRaisesRegex(ValueError, 'EFFECTIVE_PLATFORM_NAME'):
                package.parse_inputs(values)

    def test_other_dollar_values_in_paths_are_not_expanded(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / '${HOME}'
            root.mkdir()
            libraries = {}
            for core in package.DEFAULT_CORES:
                library = root / core
                library.write_bytes(b'built library')
                libraries[core] = library.resolve()
            self.assertEqual(package.parse_inputs([f'{core}={path}' for core, path in libraries.items()]),
                             libraries)

    def test_cache_verifies_every_framework_and_corresponding_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in (*[name + '.xcframework' for name in apple.FRAMEWORKS], 'notices'):
                folder = root / name
                folder.mkdir()
                (folder / 'content').write_bytes(b'fixture')
            receipt = {'sourceSha256': 'recipe', 'artifacts': {
                path.name: apple.tree_digest(path) for path in root.iterdir()}}
            (root / 'build-receipt.json').write_text(json.dumps(receipt))
            self.assertTrue(apple.cache_valid(root, 'recipe'))
            self.assertFalse(apple.cache_valid(root, 'changed recipe'))
            for artifact in receipt['artifacts']:
                path = root / artifact / 'content'
                path.write_bytes(b'changed')
                self.assertFalse(apple.cache_valid(root, 'recipe'))
                path.write_bytes(b'fixture')
            (root / 'build-receipt.json').write_text('{}')
            self.assertFalse(apple.cache_valid(root, 'recipe'))


if __name__ == '__main__':
    unittest.main()
