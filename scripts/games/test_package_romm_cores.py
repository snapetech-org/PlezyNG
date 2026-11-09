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

    def test_android_assets_keep_compressed_bytes_and_matching_receipts(self):
        old = self.stage()
        unrelated = self.output / 'retained-evidence.gz'
        unrelated.write_bytes(b'evidence')
        result = package.package(self.sources, self.libraries, self.output, 'Android', 'x86_64')
        for entry in result['cores']:
            archive = self.output / entry['sourceArchive']
            self.assertFalse(archive.name.endswith('.gz'))
            self.assertEqual(archive.read_bytes()[:2], b'\x1f\x8b')
            self.assertEqual(package.digest(archive), entry['sourceSha256'])
            with tarfile.open(archive) as source:
                self.assertTrue(any(name.endswith('/core.c') for name in source.getnames()))
        self.assertTrue(all(not (self.output / entry['sourceArchive']).exists() for entry in old['cores']))
        self.assertEqual(unrelated.read_bytes(), b'evidence')

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
    def test_framework_collection_requires_a_built_binary_not_an_xcode_stub(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            name = 'PlezyRetro'
            stub = root / 'build/EagerLinkingTBDs/Release-iphoneos' / (name + '.framework')
            stub.mkdir(parents=True)
            (stub / (name + '.tbd')).write_text('stub')
            with self.assertRaisesRegex(RuntimeError, 'found 0'):
                apple.find_framework(root, name, 'iphoneos')
            framework = root / 'Release-iphoneos' / (name + '.framework')
            framework.mkdir(parents=True)
            (framework / name).write_bytes(b'built library')
            self.assertEqual(apple.find_framework(root, name, 'iphoneos'), framework)
            other = root / 'other/Release-iphoneos' / (name + '.framework')
            other.mkdir(parents=True)
            (other / name).write_bytes(b'another library')
            with self.assertRaisesRegex(RuntimeError, 'found 2'):
                apple.find_framework(root, name, 'iphoneos')

    def test_framework_collection_accepts_versioned_macos_binary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            framework = root / 'Release/PlezyRetro.framework'
            version = framework / 'Versions/A'
            version.mkdir(parents=True)
            (version / 'PlezyRetro').write_bytes(b'built universal library')
            (framework / 'PlezyRetro').symlink_to('Versions/A/PlezyRetro')
            self.assertEqual(apple.find_framework(root, 'PlezyRetro', 'macosx'), framework)

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

    def test_macos_cache_requires_the_exact_executable_worker(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in (*[name + '.xcframework' for name in apple.FRAMEWORKS], 'notices'):
                folder = root / name
                folder.mkdir()
                (folder / 'content').write_bytes(b'fixture')

            def record():
                receipt = {'sourceSha256': 'recipe', 'artifacts': {
                    path.name: apple.tree_digest(path) for path in root.iterdir() if path.is_dir()}}
                (root / 'build-receipt.json').write_text(json.dumps(receipt))

            record()
            self.assertFalse(apple.cache_valid(root, 'recipe', 'macos'))
            (root / 'helpers').mkdir()
            helper = root / 'helpers/plezy_retro_worker'
            helper.write_bytes(b'worker fixture')
            helper.chmod(0o755)
            record()
            self.assertTrue(apple.cache_valid(root, 'recipe', 'macos'))
            helper.write_bytes(b'changed worker')
            self.assertFalse(apple.cache_valid(root, 'recipe', 'macos'))
            helper.write_bytes(b'worker fixture')
            helper.chmod(0o644)
            self.assertFalse(apple.cache_valid(root, 'recipe', 'macos'))
            helper.unlink()
            self.assertFalse(apple.cache_valid(root, 'recipe', 'macos'))

    def test_corresponding_source_contains_the_desktop_worker_and_transport(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            common, audio, output = root / 'common', root / 'audio', root / 'output'
            (common / 'include').mkdir(parents=True)
            audio.mkdir()
            (common / 'include/libretro.h').write_text('fixture API')
            (audio / 'miniaudio.h').write_text('fixture audio')
            (audio / 'LICENSE').write_text('fixture notice')
            def clean_revision(source, *args):
                return b'' if args[0] == 'diff' else b'0' * 40
            with patch.object(package, 'git', side_effect=clean_revision):
                package.stage_host_sources([f'libretro_common={common}', f'miniaudio={audio}'], output)
            for relative in (
                'native/games/romm/retro_host.cpp', 'native/games/romm/retro_proxy.cpp',
                'native/games/romm/retro_worker.cpp', 'native/games/romm/retro_protocol.h',
                'native/games/romm/retro_sandbox.h', 'native/games/romm/retro_windows_sandbox.h',
                'native/games/romm/retro_android_worker.cpp', 'native/games/romm/retro_input_files.h',
                'android/app/src/main/kotlin/com/edde746/plezy/games/RommProcessBroker.kt',
                'android/app/src/main/kotlin/com/edde746/plezy/games/RommIsolatedService.kt',
                'android/app/src/main/AndroidManifest.xml', 'android/app/proguard-rules.pro',
                'shared/process/byte_pipe.h', 'shared/process/child_process.h',
                'scripts/games/build_romm_apple.py', 'scripts/games/install_macos_worker.sh',
            ):
                self.assertEqual((output / 'build-recipe' / relative).read_bytes(),
                                 (package.ROOT / relative).read_bytes())
            self.assertTrue((output / 'host/GPL-3.0.txt').is_file())
            self.assertTrue((output / 'host/AGPL-3.0.txt').is_file())

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
