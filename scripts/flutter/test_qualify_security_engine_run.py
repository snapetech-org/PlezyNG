import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
from unittest.mock import patch

import qualify_security_engine_run as subject


class ProducerQualificationTest(unittest.TestCase):
    def setUp(self):
        self.sha = 'a' * 40
        self.run = {'id': 42, 'status': 'completed', 'conclusion': 'success', 'event': 'push',
                    'path': subject.WORKFLOW, 'head_sha': self.sha, 'head_branch': 'main',
                    'head_repository': {'id': subject.REPOSITORY_ID, 'full_name': subject.REPOSITORY,
                                        'owner': {'id': subject.OWNER_ID}}}
        self.jobs = {'total_count': 2, 'jobs': [
            {'name': f'windows ({arch})', 'run_id': 42, 'status': 'completed', 'conclusion': 'success'}
            for arch in ('x64', 'arm64')]}
        self.artifacts = {'total_count': 2, 'artifacts': [
            {'name': f'flutter-security-engine-{arch}', 'id': index + 1, 'expired': False,
             'size_in_bytes': 100, 'digest': 'sha256:' + 'b' * 64,
             'workflow_run': {'id': 42, 'head_sha': self.sha}}
            for index, arch in enumerate(('x64', 'arm64'))]}

    def test_source_blob_identity_survives_windows_crlf_checkout(self):
        committed = b'first\nsecond\n'
        checkout = b'first\r\nsecond\r\n'
        self.assertEqual(subject.source_blob(committed), subject.source_blob(checkout))
        with self.assertRaisesRegex(ValueError, 'line endings'):
            subject.source_blob(b'first\rsecond\n')

    def test_canonical_run_and_complete_pair_are_required(self):
        self.assertEqual(subject.validate_run(self.run, 42), self.sha)
        subject.validate_jobs(self.jobs, 42)
        self.assertEqual(len(subject.select_artifacts(self.artifacts, 42, self.sha)), 2)
        for key, value in [('id', 43), ('status', 'in_progress'), ('conclusion', 'failure'),
                           ('event', 'pull_request'), ('head_branch', 'topic'), ('path', 'untrusted.yml')]:
            with self.subTest(key=key):
                bad = dict(self.run, **{key: value})
                with self.assertRaises(ValueError):
                    subject.validate_run(bad, 42)
        for key, value in [('id', 1), ('full_name', 'fork/pleazyng'), ('owner', {'id': 1})]:
            with self.subTest(repository_key=key):
                bad = copy.deepcopy(self.run)
                bad['head_repository'][key] = value
                with self.assertRaises(ValueError):
                    subject.validate_run(bad, 42)

    def test_missing_failed_and_foreign_jobs_are_rejected(self):
        for change in [lambda d: d.update(total_count=3), lambda d: d['jobs'].pop(),
                       lambda d: d['jobs'][0].update(conclusion='failure'),
                       lambda d: d['jobs'][0].update(run_id=99),
                       lambda d: d['jobs'][0].update(name='untrusted')]:
            bad = copy.deepcopy(self.jobs)
            change(bad)
            with self.assertRaises(ValueError):
                subject.validate_jobs(bad, 42)

    def test_ambiguous_expired_foreign_and_oversized_artifacts_are_rejected(self):
        changes = [lambda d: d.update(total_count=3), lambda d: d['artifacts'].pop(),
                   lambda d: d['artifacts'][0].update(expired=True),
                   lambda d: d['artifacts'][0].update(size_in_bytes=5 * 1024**3),
                   lambda d: d['artifacts'][0].update(digest='missing'),
                   lambda d: d['artifacts'][0]['workflow_run'].update(id=99),
                   lambda d: d['artifacts'][0]['workflow_run'].update(head_sha='c' * 40),
                   lambda d: d['artifacts'][0].update(name=d['artifacts'][1]['name']),
                   lambda d: d['artifacts'][0].update(id=d['artifacts'][1]['id'])]
        for change in changes:
            bad = copy.deepcopy(self.artifacts)
            change(bad)
            with self.assertRaises(ValueError):
                subject.select_artifacts(bad, 42, self.sha)

    def test_source_mismatch_stops_before_downloading_or_creating_output(self):
        def api(path):
            if path == 'actions/runs/42':
                return self.run
            if '/jobs?' in path:
                return self.jobs
            return {'type': 'file', 'sha': '0' * 40}
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'out'
            with patch.object(subject, 'api', side_effect=api), patch.object(subject.subprocess, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'Producer sources changed'):
                    subject.qualify(42, output)
                run.assert_not_called()
                self.assertFalse(output.exists())

    def test_receipt_binds_verified_archives_and_producer_without_changing_pins(self):
        def api(path):
            if path == 'actions/runs/42':
                return self.run
            if '/jobs?' in path:
                return self.jobs
            if '/artifacts?' in path:
                return self.artifacts
            source = path.removeprefix('contents/').split('?')[0]
            return {'type': 'file', 'sha': subject.source_blob((subject.ROOT / source).read_bytes())}
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'out'
            def verify(root):
                archive = root / 'verified.zip'
                archive.write_bytes(b'fixture')
                archive.with_name(archive.name + '.sha256').write_text('c' * 64 + '  verified.zip\n')
                return [archive, archive.with_name(archive.name + '.sha256')]
            with patch.object(subject, 'api', side_effect=api), patch.object(subject, 'verify', side_effect=verify), \
                    patch.object(subject, 'download_artifact') as download:
                receipt = subject.qualify(42, output)
            self.assertEqual(download.call_count, 2)
            self.assertEqual({call.args[0]['id'] for call in download.call_args_list}, {1, 2})
            self.assertEqual(receipt['producerCommit'], self.sha)
            self.assertEqual(receipt['archives'][0]['sha256'], 'c' * 64)
            self.assertIs(receipt['releasePinsChanged'], False)
            self.assertEqual(receipt, json.loads((output / 'qualification.json').read_text()))


    def test_immutable_envelope_digest_and_safe_members_are_checked(self):
        archive = f'flutter-pleazyng-windows-{subject.VERSION}-x64.zip'
        for malicious, wrong_digest in [(False, False), (True, False), (False, True)]:
            with self.subTest(malicious=malicious, wrong_digest=wrong_digest), tempfile.TemporaryDirectory() as temp:
                body = io.BytesIO()
                with zipfile.ZipFile(body, 'w') as output:
                    output.writestr('../escape' if malicious else archive, b'fixture')
                    output.writestr(archive + '.sha256', b'digest fixture')
                data = body.getvalue()
                artifact = dict(self.artifacts['artifacts'][0],
                                digest='sha256:' + ('0' * 64 if wrong_digest else hashlib.sha256(data).hexdigest()))
                def download(command, **kwargs):
                    self.assertEqual(command[-1], f'repos/{subject.REPOSITORY}/actions/artifacts/1/zip')
                    self.assertTrue(kwargs['check'])
                    kwargs['stdout'].write(data)
                root = Path(temp)
                with patch.object(subject.subprocess, 'run', side_effect=download):
                    if malicious or wrong_digest:
                        with self.assertRaises(ValueError):
                            subject.download_artifact(artifact, root)
                        self.assertFalse((root / artifact['name']).exists())
                    else:
                        subject.download_artifact(artifact, root)
                        self.assertEqual((root / artifact['name'] / archive).read_bytes(), b'fixture')
                        self.assertFalse((root / (artifact['name'] + '.artifact.zip')).exists())


if __name__ == '__main__':
    unittest.main()
