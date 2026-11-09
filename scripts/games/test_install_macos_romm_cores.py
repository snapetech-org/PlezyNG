import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import install_macos_romm_cores as package


class WorkerCorePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'source'
        self.destination = self.root / 'App With Spaces.app/Contents/Frameworks'
        for name in package.CORES:
            bundle = self.source / (name + '.xcframework')
            framework = bundle / 'macos-arm64_x86_64' / (name + '.framework')
            (framework / 'Versions/A').mkdir(parents=True)
            (framework / 'Versions/A' / name).write_bytes(b'fixture executable')
            (framework / 'Versions/Current').symlink_to('A', target_is_directory=True)
            (framework / name).symlink_to('Versions/Current/' + name)
            (bundle / 'Info.plist').write_bytes(plistlib.dumps({'AvailableLibraries': [{
                'LibraryIdentifier': 'macos-arm64_x86_64', 'LibraryPath': name + '.framework',
                'SupportedPlatform': 'macos', 'SupportedArchitectures': ['arm64', 'x86_64'],
            }]}))

    def test_embeds_all_cores_without_dereferencing_version_links(self):
        with patch.object(package.subprocess, 'run') as sign:
            package.install(self.source, self.destination, identity='-')
        self.assertEqual(sign.call_count, 3)
        for name in package.CORES:
            binary = self.destination / (name + '.framework') / name
            self.assertTrue(binary.is_symlink())
            self.assertEqual(binary.read_bytes(), b'fixture executable')
        self.assertIn('--timestamp=none', sign.call_args.args[0])

    def test_rejects_external_framework_symlink(self):
        binary = package.core_slice(self.source, package.CORES[0]) / package.CORES[0]
        binary.unlink()
        binary.symlink_to(__file__)
        with self.assertRaisesRegex(ValueError, 'external symlink'):
            package.install(self.source, self.destination)
        self.assertFalse(self.destination.exists())

    def test_rejects_nonuniversal_slice_and_path_escape(self):
        name = package.CORES[0]
        manifest = self.source / (name + '.xcframework/Info.plist')
        original = plistlib.loads(manifest.read_bytes())
        for key, value in [('SupportedArchitectures', ['arm64']), ('LibraryIdentifier', '../escape')]:
            data = plistlib.loads(plistlib.dumps(original))
            data['AvailableLibraries'][0][key] = value
            manifest.write_bytes(plistlib.dumps(data))
            with self.assertRaises(ValueError):
                package.install(self.source, self.destination)

    def test_rejects_linked_destination(self):
        self.destination.mkdir(parents=True)
        (self.destination / (package.CORES[0] + '.framework')).symlink_to(self.source, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'linked core installation'):
            package.install(self.source, self.destination)

    def test_app_cannot_link_core_constructors(self):
        for name in package.CORES:
            with patch.object(package.subprocess, 'check_output', return_value=f'@rpath/{name}.framework/{name}'):
                with self.assertRaisesRegex(ValueError, 'must not link'):
                    package.verify_app_linkage(Path('app'))
        with patch.object(package.subprocess, 'check_output', return_value='@rpath/PlezyRetro.framework/PlezyRetro'):
            package.verify_app_linkage(Path('app'))


if __name__ == '__main__':
    unittest.main()
