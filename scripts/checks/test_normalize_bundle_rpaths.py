"""Exercise relocatable loader paths with real compiled dependency chains."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('rpaths', ROOT / 'linux/packaging/normalize-bundle-rpaths.py')
rpaths = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpaths)


@unittest.skipUnless(shutil.which('cc') and shutil.which('patchelf'), 'cc and patchelf required')
class BundleRpathTests(unittest.TestCase):
    def test_embedded_tool_modules_find_their_private_runtime_after_relocation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / 'bundle'
            (bundle / 'lib').mkdir(parents=True)
            runtime = bundle / 'tools/dv/lib/runtime'
            modules = bundle / 'tools/dv/lib/python3.12/lib-dynload'
            runtime.mkdir(parents=True)
            modules.mkdir(parents=True)
            (root / 'value.c').write_text('int value(void) { return 42; }\n')
            (root / 'main.c').write_text('int value(void); int main(void) { return value() != 42; }\n')
            subprocess.run(['cc', '-shared', '-fPIC', str(root/'value.c'),
                            '-o', str(runtime/'libqa_private.so')], check=True)
            subprocess.run(['cc', str(root/'main.c'), '-L'+str(runtime), '-lqa_private',
                            '-Wl,-rpath,/old/builder/runtime', '-o', str(modules/'probe')], check=True)
            rpaths.normalize(bundle)
            relocated = root / 'relocated'
            bundle.rename(relocated)
            subprocess.run([str(relocated/'tools/dv/lib/python3.12/lib-dynload/probe')], check=True)

    def test_private_dependency_chain_survives_relocation_and_paths_are_safe(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / 'bundle'
            lib = bundle / 'lib'
            nested = lib / 'providers'
            nested.mkdir(parents=True)
            (root / 'value.c').write_text('int value(void) { return 42; }\n')
            (root / 'provider.c').write_text('int value(void); int provider(void) { return value(); }\n')
            (root / 'main.c').write_text('int provider(void); int main(void) { return provider() != 42; }\n')
            subprocess.run(['cc', '-shared', '-fPIC', str(root/'value.c'), '-o', str(lib/'libvalue.so')], check=True)
            subprocess.run(['cc', '-shared', '-fPIC', str(root/'provider.c'), '-L'+str(lib), '-lvalue',
                            '-Wl,-rpath,/build/old::/usr/lib', '-o', str(nested/'libprovider.so')], check=True)
            subprocess.run(['cc', str(root/'main.c'), '-L'+str(nested), '-lprovider',
                            '-Wl,-rpath,'+str(nested), '-Wl,-rpath-link,'+str(lib),
                            '-o', str(bundle/'pleazyng')], check=True)
            # Preserve a legitimate private provider path in addition to the
            # defaults; discard builder directories and empty search entries.
            subprocess.run(['patchelf', '--set-rpath', '$ORIGIN/lib/providers:/build/old::/usr/lib',
                            str(bundle/'pleazyng')], check=True)
            (lib/'libvalue-alias.so').symlink_to('libvalue.so')
            (bundle/'model.bin').write_bytes(b'not an ELF\x00')
            self.assertGreater(rpaths.normalize(bundle), 0)
            self.assertEqual(rpaths.normalize(bundle), 0)
            relocated = root / 'relocated'
            bundle.rename(relocated)
            subprocess.run([str(relocated/'pleazyng')], check=True)
            for path in (relocated/'pleazyng', relocated/'lib/libvalue.so', relocated/'lib/providers/libprovider.so'):
                value = subprocess.check_output(['patchelf', '--print-rpath', str(path)], text=True).strip()
                self.assertTrue(all(x.startswith('$ORIGIN') for x in value.split(':')))
                self.assertNotIn('/build/', value)
            self.assertTrue((relocated/'lib/libvalue-alias.so').is_symlink())
            self.assertEqual((relocated/'model.bin').read_bytes(), b'not an ELF\x00')


if __name__ == '__main__':
    unittest.main()
