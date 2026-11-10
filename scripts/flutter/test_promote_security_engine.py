import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import promote_security_engine as subject
import qualify_native_security_engine as native


class PromotionTest(unittest.TestCase):
    def setUp(self):
        self.pins = {'x64': 'a' * 64, 'arm64': 'b' * 64}
        self.sources = {
            subject.PATHS[0]: json.dumps({'schemaVersion': 1, 'version': subject.OLD_VERSION,
                                        'frameworkRevision': subject.OLD_FRAMEWORK, 'engineRevision': subject.OLD_ENGINE}),
            subject.PATHS[1]: f"param(\n    [string]$ExpectedEngine = '{subject.OLD_ENGINE}'\n)\n# keep installer body",
            subject.PATHS[2]: f"$ExpectedEngine = '{subject.OLD_ENGINE}'",
        }

    def receipt(self, arch):
        return {'schemaVersion': 1, 'architecture': arch, 'qualificationRunId': 42,
                'producerRunId': 24, 'producerCommit': 'c' * 40,
                'frameworkVersion': subject.VERSION, 'frameworkRevision': subject.FRAMEWORK,
                'engineRevision': subject.ENGINE, 'dartRevision': subject.DART,
                'skiaRevision': subject.SKIA, 'patchRevision': subject.PATCHES,
                'depotRevision': subject.DEPOT, 'nativeMultiviewProbe': 'passed',
                'directCompositionEnabled': True, 'deviceImageQualityQualified': False,
                'archiveSha256': self.pins[arch]}

    def write_receipts(self, root, change=None):
        for arch in self.pins:
            value = self.receipt(arch)
            if change and arch == 'arm64':
                value.update(change)
            path = Path(root) / f'security-engine-native-{arch}/native-{arch}.json'
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(value))

    def test_pair_bound_to_this_run_and_sources(self):
        with tempfile.TemporaryDirectory() as root:
            self.write_receipts(root)
            self.assertEqual(subject.validate_receipts(root, 42, 24, 'c' * 40), self.pins)
            for key, value in [('qualificationRunId', 43), ('producerRunId', 25),
                               ('producerCommit', 'd' * 40), ('architecture', 'x64'),
                               ('engineRevision', 'd' * 40), ('nativeMultiviewProbe', 'failed'),
                               ('directCompositionEnabled', 1), ('schemaVersion', True),
                               ('archiveSha256', 'missing')]:
                with self.subTest(key=key):
                    self.write_receipts(root, {key: value})
                    with self.assertRaises(ValueError):
                        subject.validate_receipts(root, 42, 24, 'c' * 40)

    def test_current_source_layout_can_be_promoted(self):
        sources = {p: (subject.ROOT / p).read_text() for p in subject.PATHS}
        if json.loads(sources[subject.PATHS[0]])['version'] != subject.OLD_VERSION:
            return  # A later, qualified SDK must not be reverted by this fixed lane.
        result = subject.changes(sources, self.pins)
        self.assertEqual(json.loads(result[subject.PATHS[0]])['frameworkRevision'], subject.FRAMEWORK)
        self.assertIn('SHA256 mismatch', result['windows/tool/install-patched-engine.ps1'])

    def test_missing_pair_fails(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(ValueError):
                subject.validate_receipts(root, 42, 24, 'c' * 40)

    def test_promotion_updates_all_pins_and_is_idempotent(self):
        result = subject.changes(self.sources, self.pins)
        self.assertEqual(set(result), set(subject.PATHS))
        installer = result['windows/tool/install-patched-engine.ps1']
        for digest in self.pins.values():
            self.assertIn(digest, installer)
        self.assertIn('custom engine URL requires an explicit SHA-256', installer)
        self.assertIn(subject.ENGINE, installer)
        self.assertIn('$Architecture.zip', installer)
        self.assertEqual(subject.changes(result, self.pins), {})
        with self.assertRaises(ValueError):
            subject.changes(result, dict(self.pins, arm64='e' * 64))

    def test_later_or_partial_sdk_is_never_overwritten(self):
        for version in ['3.48.0', subject.VERSION]:
            sources = copy.deepcopy(self.sources)
            sources[subject.PATHS[0]] = sources[subject.PATHS[0]].replace(subject.OLD_VERSION, version)
            with self.assertRaises(ValueError):
                subject.changes(sources, self.pins)

    def test_native_mismatched_host_stops_before_downloading(self):
        with patch.object(native.sys, 'platform', 'win32'), patch.dict(native.os.environ, {
                'PROCESSOR_ARCHITECTURE': 'AMD64', 'PROCESSOR_ARCHITEW6432': 'AMD64'}), \
                patch.object(native, 'qualify') as qualify:
            with self.assertRaises(ValueError):
                native.native_qualify(24, 'arm64', 'unused', 'unused.json')
            qualify.assert_not_called()

    def test_atomic_promotion_writes_only_ordinary_files_and_dispatches_ci(self):
        import base64
        calls = []
        def api(path, body=None, method=None):
            calls.append((path, body, method))
            if path == 'commits/main':
                return {'sha': 'd' * 40, 'commit': {'tree': {'sha': 'e' * 40}}}
            if path.startswith('contents/'):
                source = path.removeprefix('contents/').split('?')[0]
                return {'content': base64.b64encode(self.sources[source].encode()).decode()}
            if path == 'git/trees':
                self.assertEqual(body['base_tree'], 'e' * 40)
                self.assertEqual({v['path'] for v in body['tree']}, set(subject.PATHS))
                self.assertTrue(all(not v['path'].startswith('.github/') for v in body['tree']))
                return {'sha': 'f' * 40}
            if path == 'git/commits':
                self.assertEqual(body['parents'], ['d' * 40])
                return {'sha': '1' * 40}
            if path == 'git/refs/heads/main':
                self.assertFalse(body['force'])
                self.assertEqual(method, 'PATCH')
            return None
        with patch.dict(subject.os.environ, {'GITHUB_REPOSITORY': subject.REPOSITORY,
                                           'GITHUB_REF': 'refs/heads/main'}), \
                patch.object(subject, 'validate_receipts', return_value=self.pins), \
                patch.object(subject, 'api', side_effect=api):
            subject.publish('unused', 42, 24, 'c' * 40)
        self.assertEqual(calls[-1][0], 'actions/workflows/ci.yml/dispatches')
        self.assertEqual(calls[-1][2], 'POST')

    def test_foreign_workflow_cannot_promote(self):
        with patch.dict(subject.os.environ, {'GITHUB_REPOSITORY': 'fork/pleazyng'}), \
                patch.object(subject, 'api') as api:
            with self.assertRaises(ValueError):
                subject.publish('unused', 42, 24, 'c' * 40)
            api.assert_not_called()


if __name__ == '__main__':
    unittest.main()
