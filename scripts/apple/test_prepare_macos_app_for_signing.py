import importlib.util
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('permissions', Path(__file__).with_name('prepare_macos_app_for_signing.py'))
permissions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(permissions)


class BundlePermissionsTests(unittest.TestCase):
    def test_actual_release_entitlements_canonicalize_without_effective_changes(self):
        source = Path(__file__).resolve().parents[2] / 'macos/Runner/Release.entitlements'
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'canonical.plist'
            permissions.prepare_entitlements(source, output)
            self.assertEqual(plistlib.loads(output.read_bytes()), plistlib.loads(source.read_bytes()))
            self.assertEqual(output.read_text().count('<key>com.apple.security.device.audio-input</key>'), 1)

    def test_conflicting_duplicate_entitlement_does_not_create_output(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'source.plist'
            output = Path(directory) / 'canonical.plist'
            source.write_text('<plist version="1.0"><dict><key>permission</key><true/><key>permission</key><false/></dict></plist>')
            with self.assertRaisesRegex(ValueError, 'Conflicting duplicate'):
                permissions.prepare_entitlements(source, output)
            self.assertFalse(output.exists())

    def test_readonly_framework_becomes_writable_without_content_or_execute_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Example.app'
            binary = app / 'Contents/Frameworks/Example.framework/Versions/A/Example'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'compiled binary')
            binary.chmod(0o555)
            (binary.parents[1] / 'Current').symlink_to('A')
            self.assertEqual(permissions.prepare(app), 1)
            self.assertEqual(binary.read_bytes(), b'compiled binary')
            self.assertEqual(stat.S_IMODE(binary.stat().st_mode), 0o755)

    def test_external_link_fails_before_modifying_app_or_shared_file(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Example.app'
            app.mkdir()
            shared = Path(directory) / 'shared-library'
            shared.write_bytes(b'shared cache')
            shared.chmod(0o444)
            (app / 'external').symlink_to(shared)
            with self.assertRaises(ValueError):
                permissions.prepare(app)
            self.assertEqual(stat.S_IMODE(shared.stat().st_mode), 0o444)

    def test_interrupted_signature_temporary_removed_without_changing_real_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Example.app'
            binary = app / 'Contents/Frameworks/Example.framework/Versions/A/Example'
            binary.parent.mkdir(parents=True)
            content = bytes.fromhex('cafebabe') + b'compiled universal binary'
            binary.write_bytes(content)
            temporary = binary.with_name('Example.cstemp')
            temporary.write_bytes(content + b'incomplete signature')
            permissions.prepare(app)
            self.assertFalse(temporary.exists())
            self.assertEqual(binary.read_bytes(), content)

    def test_unknown_temporary_preserved_before_permissions_change(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Example.app'
            app.mkdir()
            temporary = app / 'unknown.cstemp'
            temporary.write_bytes(b'unknown evidence')
            temporary.chmod(0o444)
            with self.assertRaises(ValueError):
                permissions.prepare(app)
            self.assertEqual(temporary.read_bytes(), b'unknown evidence')
            self.assertEqual(stat.S_IMODE(temporary.stat().st_mode), 0o444)

    def test_nfs_appledouble_removed_without_changing_resource(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Example.app'
            resource = app / 'Contents/Info.plist'
            resource.parent.mkdir(parents=True)
            resource.write_bytes(b'application metadata')
            sidecar = resource.with_name('._Info.plist')
            sidecar.write_bytes(bytes.fromhex('00051607') + b'NFS metadata')
            orphan = resource.with_name('._stripped-header')
            orphan.write_bytes(bytes.fromhex('00051607') + b'NFS metadata')
            permissions.prepare(app)
            self.assertFalse(sidecar.exists())
            self.assertFalse(orphan.exists())
            self.assertEqual(resource.read_bytes(), b'application metadata')

    def test_unknown_dot_underscore_file_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Example.app'
            app.mkdir()
            sidecar = app / '._evidence'
            sidecar.write_bytes(b'not AppleDouble')
            (app / 'evidence').write_bytes(b'keep')
            with self.assertRaises(ValueError):
                permissions.prepare(app)
            self.assertEqual(sidecar.read_bytes(), b'not AppleDouble')


if __name__ == '__main__':
    unittest.main()
