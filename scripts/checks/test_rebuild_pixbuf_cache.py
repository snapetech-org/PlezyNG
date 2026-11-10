"""Exercise native query subprocess validation without accepting partial caches."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('cache_helper', ROOT / 'linux/packaging/rebuild-pixbuf-cache.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class PixbufCacheTests(unittest.TestCase):
    def test_complete_cache_relocation_and_failed_queries_preserve_existing_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / 'bundle'
            parent = bundle / 'lib/gdk-pixbuf-2.0/2.10.0'
            modules = parent / 'loaders'
            modules.mkdir(parents=True)
            for name in ('gif', 'svg'):
                (modules / f'libpixbufloader-{name}.so').write_bytes(name.encode())
            tool = root / 'native-query'
            tool.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                            'assert os.environ["LD_LIBRARY_PATH"].split(":")[0] == sys.argv[1].split("/gdk-pixbuf")[0]\n'
                            'mode=os.environ.get("PIXBUF_TEST_MODE", "ok")\n'
                            'if mode == "exit": sys.exit(1)\n'
                            'if mode == "stderr": print("loader failed", file=sys.stderr)\n'
                            'paths=sys.argv[1:]\n'
                            'if mode == "omit": paths=paths[:-1]\n'
                            'if mode == "empty": paths=[]\n'
                            'for path in paths: print(json.dumps(path))\n')
            tool.chmod(0o755)
            helper.rebuild(bundle, tool, Path('/opt/pleazyng'))
            cache = parent / 'loaders.cache'
            self.assertEqual(len(cache.read_text().splitlines()), 2)
            self.assertIn('"/opt/pleazyng/lib/gdk-pixbuf', cache.read_text())
            expected = cache.read_bytes()
            previous = os.environ.get('PIXBUF_TEST_MODE')
            try:
                for mode in ('exit', 'stderr', 'omit', 'empty'):
                    os.environ['PIXBUF_TEST_MODE'] = mode
                    with self.subTest(mode=mode), self.assertRaises((ValueError, helper.subprocess.CalledProcessError)):
                        helper.rebuild(bundle, tool)
                    self.assertEqual(cache.read_bytes(), expected)
                self.assertEqual((modules / 'libpixbufloader-svg.so').read_bytes(), b'svg')
            finally:
                if previous is None:
                    os.environ.pop('PIXBUF_TEST_MODE', None)
                else:
                    os.environ['PIXBUF_TEST_MODE'] = previous


if __name__ == '__main__':
    unittest.main()
