"""Package boundary tests. Synthetic archives are never installable TV builds."""
import json
import hashlib
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import zipfile

import package


def elf(arch='arm'):
    data = bytearray(64)
    data[:4] = b'\x7fELF'
    data[4], machine = package.ELF_TARGETS[arch]
    data[5] = 1
    struct.pack_into('<H', data, 18, machine)
    return bytes(data)


class PackageTest(unittest.TestCase):
    def test_visualizer_provenance_records_compatible_hosted_and_private_workers(self):
        metadata, _, _, _ = self.visualizer_fixture()
        for policy in ('github-hosted', 'self-hosted', 'private-ephemeral-jit'):
            metadata['runnerPolicy'] = policy
            self.assertEqual(package.visualizer_metadata(json.dumps(metadata).encode(), 'arm')['runnerPolicy'], policy)
        metadata['runnerPolicy'] = 'local'
        with self.assertRaises(ValueError):
            package.visualizer_metadata(json.dumps(metadata).encode(), 'arm')

    def test_build_requires_the_visualizer_bundle_before_sdk_access(self):
        with self.assertRaisesRegex(ValueError, 'require.*MilkRust'):
            package.build(SimpleNamespace(visualizer_native=None, visualizer_manifest_sha256=None))

    def test_store_build_rejects_tester_emulator_and_missing_credentials(self):
        args = SimpleNamespace(store=True, tester=True, arch='arm')
        with self.assertRaisesRegex(ValueError, 'non-tester'):
            package.samsung_store_defines(args, {})
        args.tester, args.arch = False, 'x64'
        with self.assertRaisesRegex(ValueError, 'ARM'):
            package.samsung_store_defines(args, {})
        args.arch = 'arm'
        with self.assertRaisesRegex(ValueError, 'SAMSUNG_DPI'):
            package.samsung_store_defines(args, {})
        values = package.samsung_store_defines(args, {'SAMSUNG_DPI_APP_ID': 'fixture', 'SAMSUNG_DPI_SECURITY_KEY': 'test-only'})
        self.assertEqual(values['SUPPORTER_MODE'], 'iap')
        self.assertIsNone(package.samsung_store_defines(SimpleNamespace(store=False), {}))

    def test_checkout_privileges_are_added_only_to_staged_manifest_without_duplicates(self):
        staged = self.root / 'tizen-manifest.xml'
        staged.write_bytes(self.manifest)
        package.enable_samsung_checkout(staged)
        package.enable_samsung_checkout(staged)
        root = package.ET.parse(staged).getroot()
        names = [item.text for item in root.findall('t:privileges/t:privilege', package.NS)]
        self.assertEqual(names.count('http://developer.samsung.com/privilege/billing'), 1)
        self.assertEqual(names.count('http://developer.samsung.com/privilege/sso.partner'), 1)
        self.assertEqual(names.count('http://tizen.org/privilege/appmanager.launch'), 1)
        self.assertNotIn(b'sso.partner', self.manifest)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifest = (package.ROOT / 'tizen/tizen-manifest.xml').read_bytes()

    def archive(self, *, arch='arm', omit=None, extra=None, manifest=None):
        entries = {'tizen-manifest.xml': manifest or self.manifest,
                   'author-signature.xml': b'<Signature/>', 'signature1.xml': b'<Signature/>'}
        entries.update({f'lib/{name}': elf(arch) for name in
                        ('libapp.so', 'libdart_smb2.so', 'libplezy_sqlite3.so', 'libplezy_torrent.so',
                         'libflutter_engine.so', 'libflutter_plugins.so', 'libflutter_tizen_tv.so',
                         'libftpw_video_player_videohole.so')})
        entries.update({'bin/pleazyng': elf(arch), 'res/icudtl.dat': b'fixture',
                        'res/flutter_assets/AssetManifest.bin': b'fixture'})
        if arch == 'x64' and manifest is None:
            entries['tizen-manifest.xml'] = self.manifest.replace(b'api-version="6.0"', b'api-version="8.0"')
        entries.update(extra or {})
        entries.pop(omit, None)
        path = self.root / 'fixture.tpk'
        with zipfile.ZipFile(path, 'w') as archive:
            for name, content in entries.items():
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = (0o100755 if name == 'lib/plezy_visualizer_helper' else 0o100644) << 16
                archive.writestr(info, content)
        return path

    def test_helper_mode_normalization_preserves_every_signed_file(self):
        _, _, _, entries = self.visualizer_fixture()
        path = self.archive(extra=entries)
        def strip_mode(info):
            if info.filename == 'lib/plezy_visualizer_helper':
                info.create_system = 0
                info.external_attr = 0o100644 << 16
        self.rewrite_metadata(path, strip_mode)
        with zipfile.ZipFile(path) as source:
            before = {row.filename: source.read(row) for row in source.infolist()}
        with self.assertRaisesRegex(ValueError, 'not executable'):
            package.inspect_package(path, 'arm')
        self.assertTrue(package.normalize_visualizer_helper_mode(path, 'arm'))
        self.assertIsNotNone(package.inspect_package(path, 'arm')['visualizer'])
        with zipfile.ZipFile(path) as fixed:
            self.assertEqual(before, {row.filename: fixed.read(row) for row in fixed.infolist()})
            helper = fixed.getinfo('lib/plezy_visualizer_helper')
            self.assertEqual(helper.create_system, 3)
            self.assertEqual((helper.external_attr >> 16) & 0o777, 0o755)
        digest = package.sha256(path)
        self.assertFalse(package.normalize_visualizer_helper_mode(path, 'arm'))
        self.assertEqual(package.sha256(path), digest)

    def test_resigning_repairs_sdk_stripped_helper_mode(self):
        _, _, _, entries = self.visualizer_fixture()
        source = self.archive(extra=entries)
        def signer(*command, cwd=None):
            target = Path(command[-1])
            with zipfile.ZipFile(target) as archive:
                rows = [(row, archive.read(row)) for row in archive.infolist()]
            with zipfile.ZipFile(target, 'w') as archive:
                for row, contents in rows:
                    if row.filename == 'lib/plezy_visualizer_helper':
                        row.create_system = 0
                        row.external_attr = 0o100644 << 16
                    if row.filename in {'author-signature.xml', 'signature1.xml'}:
                        contents = b'<Signature>new synthetic signature</Signature>'
                    archive.writestr(row, contents)
        output = self.root / 'resigned-mode'
        with patch.object(package, 'run', side_effect=signer):
            package.resign(SimpleNamespace(package=source, sha256=package.sha256(source),
                                           arch='arm', output=output, security_profile='TV'))
        result = output / 'pleazyng-tizen-arm-signed.tpk'
        self.assertEqual(package.package_payload(source), package.package_payload(result))
        with zipfile.ZipFile(result) as archive:
            self.assertEqual((archive.getinfo('lib/plezy_visualizer_helper').external_attr >> 16) & 0o777, 0o755)

    def rewrite_metadata(self, path, update):
        with zipfile.ZipFile(path) as source:
            rows = [(row, source.read(row)) for row in source.infolist()]
        with zipfile.ZipFile(path, 'w') as target:
            for row, contents in rows:
                update(row)
                target.writestr(row, contents)

    def test_unverified_helper_cannot_gain_execute_permission(self):
        _, _, _, entries = self.visualizer_fixture()
        entries['lib/plezy_visualizer_helper'] += b'tampered'
        path = self.archive(extra=entries)
        self.rewrite_metadata(path, lambda row: setattr(row, 'external_attr', 0o100644 << 16))
        before = package.sha256(path)
        with self.assertRaisesRegex(ValueError, 'unverified visualization helper'):
            package.normalize_visualizer_helper_mode(path, 'arm')
        self.assertEqual(package.sha256(path), before)

    def test_report_is_structural_not_hardware_qualification(self):
        path = self.archive()
        report = package.inspect_package(path, 'arm')
        self.assertEqual(report['app_id'], 'org.snapetech.pleazyng')
        self.assertEqual(report['sha256'], package.sha256(path))
        self.assertTrue(report['signature_files_present'])
        self.assertFalse(report['hardware_qualified'])

    def visualizer_fixture(self, arch='arm'):
        content = {'libmilkrust_native.so': elf(arch), 'milkrust-source.tar.gz': b'synthetic source, not a build',
                   'plezy_visualizer_helper': elf(arch), 'visualizer-host-source.tar.gz': b'synthetic host source',
                   'MILKRUST-NOTICES.txt': b'synthetic fixture notice'}
        pin = json.loads((package.ROOT / 'native/visualizer/sources.lock.json').read_text())['milkrust']
        metadata = {'schemaVersion': 2, 'renderProtocol': 2, 'hostSourceRevision': 'a' * 40,
                    'abi': 2, 'sourceRevision': pin['commit'], 'target': f'tizen-{arch}',
                    'runnerPolicy': 'private-ephemeral-jit',
                    'buildRun': 'https://github.com/snapetech-org/MilkRust/actions/runs/123'}
        for name, (key, _) in package.VISUALIZER_FILES.items():
            metadata[key] = hashlib.sha256(content[name]).hexdigest()
        raw = json.dumps(metadata).encode()
        entries = {'res/visualizer/milkrust-native.json': raw}
        entries.update({('lib/' if name.endswith('.so') or name == 'plezy_visualizer_helper' else 'res/visualizer/') + name: value
                        for name, value in content.items()})
        return metadata, raw, content, entries

    def test_visualizer_requires_complete_runtime_source_notice_bundle(self):
        _, _, _, entries = self.visualizer_fixture()
        report = package.inspect_package(self.archive(extra=entries), 'arm')['visualizer']
        self.assertFalse(report['hardwareQualified'])
        self.assertFalse(report['catalogueEligible'])
        for missing in entries:
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, 'Incomplete'):
                package.inspect_package(self.archive(extra=entries, omit=missing), 'arm')
        for name in entries:
            if name.endswith('.json'):
                continue
            altered = {**entries, name: entries[name] + b'tampered'}
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'digest mismatch'):
                package.inspect_package(self.archive(extra=altered), 'arm')
        with self.assertRaisesRegex(ValueError, 'duplicate MilkRust'):
            package.inspect_package(self.archive(extra={**entries, 'other/libmilkrust_native.so': elf()}), 'arm')
        with self.assertRaisesRegex(ValueError, 'duplicate visualization helper'):
            package.inspect_package(self.archive(extra={**entries, 'other/plezy_visualizer_helper': elf()}), 'arm')

    def test_visualizer_rejects_old_helper_protocol(self):
        metadata, _, _, _ = self.visualizer_fixture()
        metadata['renderProtocol'] = 1
        with self.assertRaisesRegex(ValueError, 'identity, ABI or build provenance'):
            package.visualizer_metadata(json.dumps(metadata).encode(), 'arm')
        metadata['renderProtocol'] = 2
        metadata['schemaVersion'] = 1
        with self.assertRaisesRegex(ValueError, 'identity, ABI or build provenance'):
            package.visualizer_metadata(json.dumps(metadata).encode(), 'arm')

    def test_visualizer_stage_requires_reviewed_digest_pin_and_tv_architecture(self):
        metadata, raw, content, _ = self.visualizer_fixture()
        bundle, destination = self.root / 'visualizer', self.root / 'staged'
        bundle.mkdir()
        manifest = bundle / 'milkrust-native.json'
        manifest.write_bytes(raw)
        for name, data in content.items():
            (bundle / name).write_bytes(data)
        reviewed = hashlib.sha256(raw).hexdigest()
        with self.assertRaisesRegex(ValueError, 'reviewed digest'):
            package.stage_visualizer(package.ROOT, destination, bundle, '0' * 64, 'arm')
        package.stage_visualizer(package.ROOT, destination, bundle, reviewed, 'arm')
        self.assertEqual((destination / 'tizen/lib/libmilkrust_native.so').read_bytes(), content['libmilkrust_native.so'])
        self.assertEqual((destination / 'tizen/lib/plezy_visualizer_helper').stat().st_mode & 0o777, 0o755)
        metadata['sourceRevision'] = '0' * 40
        manifest.write_text(json.dumps(metadata))
        with self.assertRaisesRegex(ValueError, 'app source pin'):
            package.stage_visualizer(package.ROOT, destination, bundle, package.sha256(manifest), 'arm')
        metadata, _, _, _ = self.visualizer_fixture()
        (bundle / 'libmilkrust_native.so').write_bytes(elf('x64'))
        metadata['librarySha256'] = package.sha256(bundle / 'libmilkrust_native.so')
        manifest.write_text(json.dumps(metadata))
        with self.assertRaisesRegex(ValueError, 'wrong TV architecture'):
            package.stage_visualizer(package.ROOT, destination, bundle, package.sha256(manifest), 'arm')

    def test_emulator_or_mixed_abi_cannot_pass_as_tv(self):
        for path in (self.archive(arch='x64', manifest=self.manifest),):
            with self.assertRaisesRegex(ValueError, 'Wrong architecture'):
                package.inspect_package(path, 'arm')
        path = self.archive(extra={'lib/plugin.so': elf('x64')})
        with self.assertRaisesRegex(ValueError, 'Wrong architecture'):
            package.inspect_package(path, 'arm')

    def test_signature_storage_library_and_identity_are_required(self):
        for omit in ('signature1.xml', 'lib/libdart_smb2.so', 'lib/libplezy_sqlite3.so', 'lib/libplezy_torrent.so',
                     'lib/libflutter_engine.so', 'lib/libflutter_plugins.so',
                     'lib/libftpw_video_player_videohole.so', 'bin/pleazyng', 'res/icudtl.dat'):
            with self.subTest(omit=omit), self.assertRaises(ValueError):
                package.inspect_package(self.archive(omit=omit), 'arm')
        with self.assertRaisesRegex(ValueError, 'identity'):
            package.inspect_package(self.archive(manifest=self.manifest.replace(b'org.snapetech.pleazyng', b'other.app')), 'arm')

    def test_private_material_and_unsafe_paths_are_rejected(self):
        for name in ('cert/author.p12', 'distributor.pfx', 'private.key', 'profiles.xml', '.env', '../escape', '/absolute', 'dir\\file'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                package.inspect_package(self.archive(extra={name: b'private'}), 'arm')
        path = self.archive()
        with zipfile.ZipFile(path, 'a') as archive:
            info = zipfile.ZipInfo('link')
            info.external_attr = 0o120777 << 16
            archive.writestr(info, 'outside')
        with self.assertRaisesRegex(ValueError, 'Unsafe'):
            package.inspect_package(path, 'arm')

    def test_manifest_entities_are_not_expanded(self):
        raw = b'<!DOCTYPE manifest [<!ENTITY x "unsafe">]>' + self.manifest
        with self.assertRaisesRegex(ValueError, 'Unsafe manifest'):
            package.inspect_package(self.archive(manifest=raw), 'arm')

    def test_catalogue_excludes_emulator_and_is_disabled(self):
        import re
        recipe = json.loads((package.ROOT / 'packaging/tizen/apps2samsung.json').read_text())
        self.assertFalse(recipe['enabled'])
        pattern = recipe['assets'][0]['match']
        self.assertIsNotNone(re.fullmatch(pattern, 'pleazyng-tizen-arm.tpk'))
        for name in ('pleazyng-tizen-x64.tpk', 'pleazyng-tizen-arm-tester.tpk', 'pleazyng-tizen-arm-signed.tpk',
                     'pleazyng-tizen-arm.tpk.sha256', 'Other-tizen-arm.tpk'):
            self.assertIsNone(re.fullmatch(pattern, name))

    def test_api_floor_and_launcher_abi_are_checked(self):
        with self.assertRaisesRegex(ValueError, 'Expected API'):
            package.inspect_package(self.archive(manifest=self.manifest.replace(b'api-version="6.0"', b'api-version="2.24.1"')), 'arm')
        with self.assertRaisesRegex(ValueError, 'Wrong architecture'):
            package.inspect_package(self.archive(extra={'bin/pleazyng': elf('x64')}), 'arm')
        self.assertEqual(package.inspect_package(self.archive(arch='x64'), 'x64')['minimum_api'], '8.0')

    def test_resign_rejects_digest_mismatch_without_running_signer(self):
        args = SimpleNamespace(package=self.archive(), sha256='0' * 64, arch='arm',
                               security_profile='test', output=self.root / 'signed')
        with patch.object(package, 'run') as signer, self.assertRaisesRegex(ValueError, 'SHA-256'):
            package.resign(args)
        signer.assert_not_called()

    def test_resign_preserves_payload_and_rejects_noop_or_changed_app(self):
        source = self.archive()
        for kind in ('valid', 'noop', 'tampered'):
            args = SimpleNamespace(package=source, sha256=package.sha256(source), arch='arm',
                                   security_profile='test', output=self.root / kind)
            def signer(*command, **kwargs):
                if kind == 'noop':
                    return
                path = Path(command[-1])
                with zipfile.ZipFile(path) as archive:
                    entries = {row.filename: archive.read(row) for row in archive.infolist()}
                entries['author-signature.xml'] = b'<Signature>replacement fixture</Signature>'
                if kind == 'tampered':
                    entries['res/icudtl.dat'] = b'changed app'
                with zipfile.ZipFile(path, 'w') as archive:
                    for name, content in entries.items():
                        archive.writestr(name, content)
            with self.subTest(kind=kind), patch.object(package, 'run', side_effect=signer):
                if kind == 'valid':
                    package.resign(args)
                    report = json.loads((args.output / 'pleazyng-tizen-arm-signed.tpk.json').read_text())
                    self.assertTrue(report['payload_unchanged'])
                    self.assertFalse(report['tv_install_verified'])
                else:
                    with self.assertRaisesRegex(ValueError, 'no change' if kind == 'noop' else 'changed the application'):
                        package.resign(args)
                    self.assertFalse((args.output / 'pleazyng-tizen-arm-signed.tpk').exists())

    def test_stage_keeps_overrides_excludes_untracked_and_checks_native_digests(self):
        source, stage, native = [self.root / p for p in ('source', 'stage', 'native')]
        for directory in (source, stage, native):
            directory.mkdir()
        subprocess.run(['git', 'init', '-q', source], check=True)
        files = {
            'pubspec.yaml': 'name: fixture\nversion: 3.4.5+7\ndependencies:\n  pdfrx: ^2.10.1\ndependency_overrides:\n  existing:\n    path: packages/existing\n',
            'tizen/tizen-manifest.xml': self.manifest.decode(),
            'scripts/tizen/smb_build_hook.dart': '// staged hook',
            'scripts/tizen/publication_reader_screen.dart': '// TV reader',
            'scripts/tizen/romm_manual_view.dart': '// TV manual',
            'assets/pleazyng.png': 'fixture image',
        }
        for name, content in files.items():
            p = source / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content)
        subprocess.run(['git', '-C', source, 'add', '.'], check=True)
        (source / 'author.p12').write_text('must not copy')
        smb = self.root / 'pub-cache/dart_smb2'
        (smb / 'hook').mkdir(parents=True)
        (smb / 'pubspec.yaml').write_text('name: dart_smb2\nversion: 0.2.3\n')
        (smb / 'hook/build.dart').write_text('// upstream hook')
        (source / '.dart_tool').mkdir()
        (source / '.dart_tool/package_config.json').write_text(json.dumps({'packages': [{'name': 'dart_smb2', 'rootUri': smb.as_uri()}]}))
        report = {'architecture': 'arm', 'pins': package.PINS, 'libraries': {}}
        for name in ('libdart_smb2.so', 'libplezy_sqlite3.so', 'libplezy_torrent.so'):
            p = native / name
            p.write_bytes(elf())
            report['libraries'][name] = package.sha256(p)
        (native / 'native-build.json').write_text(json.dumps(report))
        package.stage(source, stage, native, 'arm')
        pubspec = (stage / 'pubspec.yaml').read_text()
        self.assertIn('path: packages/existing', pubspec)
        self.assertNotIn('pdfrx:', pubspec)
        self.assertEqual((stage / 'lib/screens/sources/publication_reader_screen.dart').read_text(), '// TV reader')
        self.assertEqual((stage / 'lib/screens/games/romm_manual_view.dart').read_text(), '// TV manual')
        self.assertIn('path: packages/dart_smb2_tizen', pubspec)
        self.assertFalse((stage / 'author.p12').exists())
        self.assertIn('version="3.4.5"', (stage / 'tizen/tizen-manifest.xml').read_text())
        self.assertIn('api-version="6.0"', (stage / 'tizen/tizen-manifest.xml').read_text())
        self.assertEqual((smb / 'hook/build.dart').read_text(), '// upstream hook')
        self.assertEqual((stage / 'packages/dart_smb2_tizen/hook/build.dart').read_text(), '// staged hook')
        (native / 'libdart_smb2.so').write_bytes(elf() + b'tampered')
        with self.assertRaisesRegex(ValueError, 'Native input mismatch'):
            package.stage(source, self.root / 'invalid-stage', native, 'arm')


class PdfAdapterPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        subprocess.run(['git', 'init', '-q', self.root], check=True)
        self.files = {
            'lib/screens/sources/publication_reader_screen.dart': "import 'package:pdfrx/pdfrx.dart';",
            'lib/screens/games/romm_manual_view.dart': "import 'package:pdfrx/pdfrx.dart';",
            'lib/screens/games/romm_detail_screen.dart': "import 'romm_manual_view.dart';",
            **{value: '// Compatible TV adapter' for value in package.PDF_READER_ADAPTERS.values()},
        }
        for name, text in self.files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        subprocess.run(['git', '-C', self.root, 'add', '.'], check=True)

    def test_staged_adapters_keep_the_normal_pdf_sources_unchanged(self):
        before = {name: (self.root / name).read_bytes() for name in self.files}
        package.preflight_pdf_readers(self.root)
        self.assertEqual(before, {name: (self.root / name).read_bytes() for name in self.files})

    def test_original_romm_import_fails_before_any_native_build(self):
        target = self.root / 'lib/screens/games/romm_detail_screen.dart'
        target.write_text("import 'package:pdfrx/pdfrx.dart';")
        with self.assertRaisesRegex(ValueError, 'romm_detail_screen.dart: package:pdfrx/'):
            package.preflight_pdf_readers(self.root)

    def test_conditional_pdf_engine_imports_are_not_missed(self):
        target = self.root / 'lib/screens/games/romm_detail_screen.dart'
        target.write_text("export 'base.dart' if (dart.library.io) 'package:pdfrx_engine/pdfrx_engine.dart';")
        with self.assertRaisesRegex(ValueError, 'package:pdfrx_engine/'):
            package.preflight_pdf_readers(self.root)

    def test_comment_and_executable_examples_are_inert(self):
        target = self.root / 'lib/screens/games/romm_detail_screen.dart'
        target.write_text("// import 'package:pdfrx/pdfrx.dart';\nimport 'romm_manual_view.dart';\n"
                          'const example = "import \'package:pdfrx/pdfrx.dart\';";')
        package.preflight_pdf_readers(self.root)

    def test_missing_tv_adapter_is_rejected(self):
        (self.root / 'scripts/tizen/romm_manual_view.dart').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing tracked Tizen PDF adapter'):
            package.preflight_pdf_readers(self.root)


if __name__ == '__main__':
    unittest.main()
