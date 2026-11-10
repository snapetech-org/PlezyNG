"""Exercise native query subprocess validation without accepting partial caches."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('cache_helper', ROOT / 'linux/packaging/aerynos/rebuild-im-cache.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class InputMethodCacheTests(unittest.TestCase):
    def test_complete_cache_relocation_and_failed_queries_preserve_existing_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / 'bundle'
            parent = bundle / 'lib/gtk-3.0/3.0.0'
            modules = parent / 'immodules'
            modules.mkdir(parents=True)
            for name in ('viqr', 'cyrillic-translit'):
                (modules / f'im-{name}.so').write_bytes(name.encode())
            tool = root / 'native-query'
            tool.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                            'assert os.environ["LD_LIBRARY_PATH"].split(":")[0] == sys.argv[1].split("/gtk-3.0")[0]\n'
                            'mode=os.environ.get("IM_CACHE_TEST_MODE", "ok")\n'
                            'if mode == "exit": sys.exit(1)\n'
                            'if mode == "stderr": print("loader failed", file=sys.stderr)\n'
                            'paths=sys.argv[1:]\n'
                            'if mode == "omit": paths=paths[:-1]\n'
                            'if mode == "empty": paths=[]\n'
                            'for path in paths: print(json.dumps(path))\n')
            tool.chmod(0o755)
            helper.rebuild(bundle, tool, Path('/opt/pleazyng'))
            cache = parent / 'immodules.cache'
            self.assertEqual(len(cache.read_text().splitlines()), 2)
            self.assertIn('"/opt/pleazyng/lib/gtk-3.0', cache.read_text())
            expected = cache.read_bytes()
            previous = os.environ.get('IM_CACHE_TEST_MODE')
            try:
                for mode in ('exit', 'stderr', 'omit', 'empty'):
                    os.environ['IM_CACHE_TEST_MODE'] = mode
                    with self.subTest(mode=mode), self.assertRaises((ValueError, helper.subprocess.CalledProcessError)):
                        helper.rebuild(bundle, tool)
                    self.assertEqual(cache.read_bytes(), expected)
                self.assertEqual((modules / 'im-cyrillic-translit.so').read_bytes(), b'cyrillic-translit')
            finally:
                if previous is None:
                    os.environ.pop('IM_CACHE_TEST_MODE', None)
                else:
                    os.environ['IM_CACHE_TEST_MODE'] = previous


if __name__ == '__main__':
    unittest.main()
