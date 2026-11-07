import importlib.util
from pathlib import Path
import stat
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('permissions', Path(__file__).with_name('prepare_macos_app_for_signing.py'))
permissions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(permissions)


class BundlePermissionsTests(unittest.TestCase):
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


if __name__ == '__main__':
    unittest.main()
