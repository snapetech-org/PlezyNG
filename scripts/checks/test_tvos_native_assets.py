#!/usr/bin/env python3
"""Reject wrong-platform native assets and preserve the locked SQLite ABI."""
from pathlib import Path
import hashlib
import importlib.util
import io
import json
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('tvos_native_assets', ROOT / 'tvos/scripts/stage_native_assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class TvosNativeAssetTests(unittest.TestCase):
    def test_ios_binary_and_missing_dart_ffi_exports_are_rejected(self):
        for platform, exported in (('7', '_sqlite3_initialize'), ('8', '_sqlite3_open_v2')):
            with self.subTest(platform=platform), patch.object(assets, 'run', side_effect=[
                'arm64', f'cmd LC_BUILD_VERSION\n platform {platform}\n minos 17.0\n', exported,
            ]):
                with self.assertRaises(ValueError):
                    assets.validate_binary(Path('sqlite3'), 'appletvsimulator', ['arm64'], {'sqlite3_initialize'})

    def test_verified_source_reads_only_the_pinned_member(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            content = io.BytesIO()
            with zipfile.ZipFile(content, 'w') as archive:
                archive.writestr('source/sqlite3.c', '#define SQLITE_VERSION        "3.53.3"\n')
                archive.writestr('../escape', 'not extracted')
            pin = {'archiveSha256': hashlib.sha256(content.getvalue()).hexdigest(),
                   'archiveRoot': 'source', 'archiveUrl': 'https://sqlite.org/source.zip', 'sqliteVersion': '3.53.3'}
            with patch.object(assets, 'urlopen', return_value=io.BytesIO(content.getvalue())):
                source = assets.sqlite_source(root, pin)
            self.assertIn('3.53.3', source.read_text())
            self.assertFalse((root / 'escape').exists())
            pin['archiveSha256'] = '0' * 64
            with patch.object(assets, 'urlopen', return_value=io.BytesIO(content.getvalue())):
                with self.assertRaisesRegex(ValueError, 'checksum'):
                    assets.sqlite_source(root, pin)

    def test_staging_rebuilds_for_tvos_and_preserves_package_compile_options(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'tvos').mkdir()
            pin = {'packageVersion': '3.5.0', 'sqliteVersion': '3.53.3'}
            (root / 'tvos/sqlite-source.lock.json').write_text(json.dumps(pin))
            (root / 'pubspec.lock').write_text('  sqlite3:\n    version: "3.5.0"\n')
            package = root / 'package'
            hook = package / 'lib/src/hook/compile'
            hook.mkdir(parents=True)
            (hook.parent / 'asset_hashes.dart').write_text("const releaseTag = 'sqlite3-3.5.0';")
            (hook / 'description.dart').write_text("const _defaultDefines = '''SQLITE_ENABLE_FTS5 SQLITE_ENABLE_SESSION''';")
            (hook / 'used_symbols.dart').write_text("const symbols = {'sqlite3_initialize', 'sqlite3_column_table_name'};")
            (root / '.dart_tool').mkdir()
            (root / '.dart_tool/package_config.json').write_text(json.dumps({'packages': [
                {'name': 'sqlite3', 'rootUri': package.as_uri()},
            ]}))
            template = root / 'input/sqlite3.framework'
            template.mkdir(parents=True)
            (template / 'sqlite3').write_bytes(b'wrong-platform-ios')
            (template / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleSupportedPlatforms': ['iPhoneOS']}))
            source = root / 'sqlite3.c'
            source.write_text('source')
            commands = []

            def compile(command, **kwargs):
                commands.append(command)
                Path(command[command.index('-o') + 1]).write_bytes(b'genuine-tvos')

            with patch.object(assets, 'sqlite_source', return_value=source), \
                    patch.object(assets, 'run', side_effect=['/SDK', 'arm64', 'platform 8\n', '_sqlite3_initialize']), \
                    patch.object(assets.subprocess, 'run', side_effect=compile):
                assets.stage(root, template.parent, root / 'output', 'appletvsimulator', ['arm64'], '17.0')
            framework = root / 'output/sqlite3.framework'
            self.assertEqual((framework / 'sqlite3').read_bytes(), b'genuine-tvos')
            self.assertEqual((template / 'sqlite3').read_bytes(), b'wrong-platform-ios')
            command = commands[0]
            self.assertIn('arm64-apple-tvos17.0-simulator', command)
            self.assertIn('-DSQLITE_ENABLE_FTS5', command)
            self.assertIn('-DSQLITE_ENABLE_SESSION', command)
            metadata = plistlib.loads((framework / 'Info.plist').read_bytes())
            self.assertEqual(metadata['CFBundleSupportedPlatforms'], ['AppleTVSimulator'])
            self.assertEqual(metadata['MinimumOSVersion'], '17.0')
            self.assertTrue((framework / 'pleazyng-source.json').is_file())
            self.assertIn('sqlite3_column_table_name', assets.required_symbols(package, ['SQLITE_ENABLE_COLUMN_METADATA']))

    def test_unported_native_assets_cannot_be_silently_omitted_or_copied_from_ios(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ('sqlite3', 'unported'):
                (root / f'input/{name}.framework').mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, 'Unported'):
                assets.stage(root, root / 'input', root / 'output', 'appletvsimulator', ['arm64'], '17.0')


if __name__ == '__main__':
    unittest.main()
