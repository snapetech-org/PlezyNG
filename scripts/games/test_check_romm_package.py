import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import check_romm_package as package


class AndroidRommTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.entries = {'lib/arm64-v8a/libplezy_retro.so': b'host',
                        'lib/arm64-v8a/libplezy_retro_worker.so': b'worker'}
        records = []
        for core in sorted(package.DEFAULT_CORES):
            self.entries[f'lib/arm64-v8a/lib{core}_libretro.so'] = b'core'
            prefix = 'assets/romm-notices/arm64-v8a/'
            self.entries[prefix + core + '.tar.gz'] = b'source archive'
            self.entries[prefix + core + '.LICENSE'] = b'license'
            records.append({'core': core, 'commit': package.PINS[core]['commit'],
                'sourceArchive': core + '.tar.gz',
                'sourceSha256': hashlib.sha256(b'source archive').hexdigest(),
                'licenses': [core + '.LICENSE']})
        self.manifest = 'assets/romm-notices/arm64-v8a/romm-cores.json'
        self.entries[self.manifest] = json.dumps({'schemaVersion': 1, 'platform': 'Android',
            'architecture': 'arm64-v8a', 'cores': records}).encode()

    def check(self, *, apk=True, elf=''):
        path = self.root / 'app.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            for name, data in self.entries.items():
                archive.writestr(name if apk else 'base/' + name, data)
        with zipfile.ZipFile(path) as archive, patch.object(package, 'inspect_elf') as inspect, \
                patch.object(package.subprocess, 'check_output', return_value=elf):
            report = package.check_romm(archive, {'arm64-v8a'}, Path('readelf'), self.root, is_apk=apk)
            self.assertEqual(inspect.call_count, 5)
            contracts = [call.args[2] for call in inspect.call_args_list]
            host = next(exports for exports in contracts if 'plezy_retro_open' in exports)
            self.assertIn('plezy_retro_isolation_version', host)
            self.assertIn('Java_com_edde746_plezy_games_RommProcessBroker_initialize', host)
            self.assertNotIn('plezy_retro_read_audio', host)
            self.assertIn({'Java_com_edde746_plezy_games_RommIsolatedService_runWorker'}, contracts)
            return report

    def test_apk_and_bundle_inspect_host_worker_and_cores(self):
        self.assertEqual(len(self.check()), 5)
        self.assertEqual(len(self.check(apk=False)), 5)

    def test_missing_isolated_worker_rejected(self):
        self.entries.pop('lib/arm64-v8a/libplezy_retro_worker.so')
        with self.assertRaisesRegex(ValueError, 'library set'):
            self.check()

    def test_proxy_cannot_load_worker_or_core_as_linker_dependency(self):
        for name in ('libplezy_retro_worker.so', 'libgambatte_libretro.so'):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'app proxy must not link'):
                self.check(elf=f'(NEEDED) Shared library: [{name}]')

    def test_missing_core_or_additional_abi_rejected(self):
        self.entries.pop('lib/arm64-v8a/libmgba_libretro.so')
        with self.assertRaisesRegex(ValueError, 'library set'):
            self.check()

    def test_wrong_source_digest_rejected(self):
        self.entries['assets/romm-notices/arm64-v8a/mgba.tar.gz'] = b'changed'
        with self.assertRaisesRegex(ValueError, 'digest'):
            self.check()

    def test_wrong_receipt_abi_and_revision_rejected(self):
        receipt = json.loads(self.entries[self.manifest])
        for field, value in [('architecture', 'x86_64'), ('platform', 'Linux')]:
            changed = dict(receipt, **{field: value})
            self.entries[self.manifest] = json.dumps(changed).encode()
            with self.assertRaisesRegex(ValueError, 'receipt'):
                self.check()
        receipt['cores'][0]['commit'] = '0' * 40
        self.entries[self.manifest] = json.dumps(receipt).encode()
        with self.assertRaisesRegex(ValueError, 'revision'):
            self.check()

    def test_missing_license_rejected(self):
        self.entries.pop('assets/romm-notices/arm64-v8a/mgba.LICENSE')
        with self.assertRaisesRegex(ValueError, 'Missing RomM'):
            self.check()


if __name__ == '__main__':
    unittest.main()
