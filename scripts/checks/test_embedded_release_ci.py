"""A captured main run must qualify every required child before stable-tag creation."""
from copy import deepcopy
import json
from pathlib import Path
import os
import sys
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

import verify_embedded_release_ci as embedded
import recover_release_platforms as recovery
from verify_release_ci import GateError, _manifest_gate


class EmbeddedQualificationTests(unittest.TestCase):
    sha = 'a' * 40
    tag = 'v3.0.31'

    def setUp(self):
        self.required = _manifest_gate()['requiredJobs']
        self.run = {'id': 42, 'run_attempt': 2, 'event': 'workflow_dispatch',
                    'head_branch': 'main', 'head_sha': self.sha, 'status': 'in_progress',
                    'path': '.github/workflows/build.yml',
                    'repository': {'id': embedded.REPOSITORY_ID},
                    'head_repository': {'id': embedded.REPOSITORY_ID}}
        self.jobs = [{'id': i + 1, 'run_attempt': 2, 'name': embedded.PREFIX + name,
                      'status': 'completed', 'conclusion': 'success'} for i, name in enumerate(self.required)]

    def verify(self, run=None, jobs=None):
        return embedded.verify_jobs(self.run if run is None else run,
            self.jobs if jobs is None else jobs, self.sha, 42, 2, self.required)

    def test_current_run_need_not_complete_before_its_platforms_start(self):
        proof = self.verify()
        self.assertEqual(proof['mode'], 'embedded')
        self.assertEqual(len(proof['jobs']), len(self.required))
        self.assertEqual(proof['attempt'], 2)

    def test_foreign_source_event_workflow_repository_or_attempt_is_rejected(self):
        for field, value in [('id', 43), ('run_attempt', 1), ('head_sha', 'b' * 40),
                             ('head_branch', 'untrusted'), ('event', 'pull_request'),
                             ('path', '.github/workflows/ci.yml'), ('repository', {'id': 1}),
                             ('head_repository', {'id': 1})]:
            with self.subTest(field=field), self.assertRaises(GateError):
                self.verify(run={**self.run, field: value})

    def test_every_required_child_must_be_unique_completed_and_successful(self):
        variants = [self.jobs[1:], self.jobs + [self.jobs[0]]]
        for change in ({'conclusion': 'failure'}, {'conclusion': 'skipped'}, {'status': 'in_progress'},
                       {'name': 'Unrelated / ' + self.required[0]}):
            jobs = deepcopy(self.jobs)
            jobs[0].update(change)
            variants.append(jobs)
        for jobs in variants:
            with self.subTest(jobs=jobs[:1]), self.assertRaises(GateError):
                self.verify(jobs=jobs)

    def test_new_attempt_failure_cannot_be_hidden_by_an_old_success(self):
        jobs = deepcopy(self.jobs)
        jobs[0]['conclusion'] = 'failure'
        old = {**self.jobs[0], 'run_attempt': 1}
        for graph in (jobs, jobs + [old]):
            with self.subTest(duplicate=len(graph)), self.assertRaises(GateError):
                self.verify(jobs=graph)

    def test_github_reused_passing_children_retain_their_original_attempt(self):
        jobs = [{**job, 'run_attempt': 1} for job in self.jobs]
        self.assertEqual(self.verify(jobs=jobs)['jobs'][0]['attempt'], 1)

    def test_a_failed_optional_child_also_blocks_freezing(self):
        jobs = self.jobs + [{'id': 99, 'name': embedded.PREFIX + 'Optional smoke',
                            'status': 'completed', 'conclusion': 'failure'}]
        with self.assertRaises(GateError):
            self.verify(jobs=jobs)

    def recover(self, *, jobs=None, run=None):
        source_run = {**self.run, 'status': 'completed', 'conclusion': 'failure', 'html_url': 'https://example.test/run/42'}
        source_jobs = self.jobs + [
            {'id': 98, 'name': 'Freeze qualified source', 'status': 'completed', 'conclusion': 'success'},
            {'id': 99, 'name': 'build-ios', 'status': 'completed', 'conclusion': 'failure'}]
        manifest = {'release': {'releaseGate': {'requiredJobs': self.required}}}
        with patch.object(recovery, 'api', side_effect=[source_run if run is None else run,
                {'status': 'ahead', 'base_commit': {'sha': self.sha}}]), \
                patch.object(recovery, 'collection', return_value=source_jobs if jobs is None else jobs), \
                patch.object(recovery, 'immutable_content', return_value=json.dumps(manifest)):
            return recovery.embedded_source_ci(embedded.REPOSITORY, self.sha, 42)

    def test_platform_failure_does_not_erase_original_embedded_qualification(self):
        proof = self.recover()
        self.assertEqual(proof['ci_run_id'], 42)
        self.assertEqual(proof['ci_mode'], 'embedded')
        self.assertEqual(proof['embedded_ci']['source_sha'], self.sha)

    def test_recovery_rejects_failed_missing_duplicate_freeze_or_child(self):
        freeze = {'id': 98, 'name': 'Freeze qualified source', 'status': 'completed', 'conclusion': 'success'}
        variants = [self.jobs, self.jobs + [freeze, freeze],
                    self.jobs + [{**freeze, 'conclusion': 'failure'}],
                    self.jobs[1:] + [freeze],
                    [{**self.jobs[0], 'conclusion': 'failure'}] + self.jobs[1:] + [freeze]]
        for jobs in variants:
            with self.subTest(jobs=len(jobs)), self.assertRaises((GateError, recovery.RecoveryError)):
                self.recover(jobs=jobs)

    def test_recovery_cannot_substitute_another_run_or_source(self):
        for change in ({'id': 43}, {'head_sha': 'b' * 40}, {'head_repository': {'id': 1}},
                       {'run_attempt': 0}):
            with self.subTest(change=change), self.assertRaises((GateError, recovery.RecoveryError)):
                self.recover(run={**self.run, **change})

    def test_legacy_source_without_embedded_ci_retains_standalone_path(self):
        self.assertIsNone(self.recover(jobs=[{'name': 'build-ios'}]))

    def test_recognized_embedded_failure_never_falls_back_to_standalone_success(self):
        with patch.dict(os.environ, {'GH_TOKEN': 'fixture'}), \
                patch.object(recovery, 'immutable_ci_source', return_value=self.sha), \
                patch.object(recovery, 'embedded_source_ci', side_effect=GateError('failed child')), \
                patch.object(recovery.release_ci, '_latest_run') as standalone, self.assertRaises(GateError):
            recovery.ci_proof(embedded.REPOSITORY, self.sha, '3.0.31', source_run=42)
        standalone.assert_not_called()

    def candidate(self, *, tag=None, candidate=None, ancestry='ahead', stable=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'pubspec.yaml').write_text('version: 3.0.31+190\n')
            with patch.object(embedded, 'resolve_ref', side_effect=[self.sha, stable]), \
                    patch.object(embedded, 'api', return_value={'status': ancestry, 'base_commit': {'sha': self.sha}}):
                embedded.verify_candidate('fixture', embedded.REPOSITORY, self.sha, tag or self.tag,
                    candidate or f'{self.tag}-candidate.{self.sha}', root=root)

    def test_candidate_remains_valid_when_main_advances(self):
        self.candidate()

    def test_wrong_candidate_sha_version_ancestry_and_existing_tag_are_rejected(self):
        for change in ({'candidate': f'{self.tag}-candidate.' + 'b' * 40},
                       {'tag': 'v3.0.32'}, {'ancestry': 'diverged'}, {'stable': 'b' * 40}):
            with self.subTest(change=change), self.assertRaises(GateError):
                self.candidate(**change)

    def test_existing_stable_tag_is_never_retargeted(self):
        with patch.object(embedded, 'resolve_ref', return_value='b' * 40), \
                patch.object(embedded, 'api') as api, self.assertRaises(GateError):
            embedded.create_stable_tag('fixture', self.tag, self.sha)
        api.assert_not_called()

    def test_stable_creation_uses_an_annotated_tag_at_the_qualified_sha(self):
        with patch.object(embedded, 'resolve_ref', side_effect=[None, self.sha]), \
                patch.object(embedded, 'api', side_effect=[{'sha': 'c' * 40}, {}]) as api:
            embedded.create_stable_tag('fixture', self.tag, self.sha)
        self.assertEqual(api.call_args_list[0].kwargs['payload']['object'], self.sha)
        self.assertEqual(api.call_args_list[1].kwargs['payload'], {'ref': f'refs/tags/{self.tag}', 'sha': 'c' * 40})

    def test_new_ref_and_annotated_object_visibility_are_retried_without_duplicate_posts(self):
        with patch.object(embedded, 'resolve_ref', side_effect=[None, None,
                embedded.QualificationNotFound('object unavailable'), self.sha]), \
                patch.object(embedded, 'api', side_effect=[{'sha': 'c' * 40}, {}]) as api, \
                patch.object(embedded.time, 'sleep') as sleep:
            embedded.create_stable_tag('fixture', self.tag, self.sha)
        self.assertEqual(api.call_count, 2)
        self.assertEqual(sleep.call_count, 2)

    def test_unavailable_new_tag_stops_after_bounded_reads_and_preserves_created_ref(self):
        with patch.object(embedded, 'resolve_ref', return_value=None) as resolve, \
                patch.object(embedded, 'api', side_effect=[{'sha': 'c' * 40}, {}]) as api, \
                patch.object(embedded.time, 'sleep') as sleep, \
                self.assertRaisesRegex(GateError, 'preserve it'):
            embedded.create_stable_tag('fixture', self.tag, self.sha)
        self.assertEqual(resolve.call_count, 6)
        self.assertEqual(api.call_count, 2)
        self.assertEqual(sleep.call_count, 4)

    def test_wrong_new_tag_or_non404_read_failure_is_never_retried_or_retargeted(self):
        for visible in ('b' * 40, GateError('HTTP403')):
            with self.subTest(visible=visible), \
                    patch.object(embedded, 'resolve_ref', side_effect=[None, visible]), \
                    patch.object(embedded, 'api', side_effect=[{'sha': 'c' * 40}, {}]) as api, \
                    patch.object(embedded.time, 'sleep') as sleep, self.assertRaises(GateError):
                embedded.create_stable_tag('fixture', self.tag, self.sha)
            self.assertEqual(api.call_count, 2)
            sleep.assert_not_called()

    def test_ref_post_race_reuses_only_the_same_qualified_tag(self):
        with patch.object(embedded, 'resolve_ref', side_effect=[None, None, self.sha]), \
                patch.object(embedded, 'api', side_effect=[{'sha': 'c' * 40}, GateError('HTTP422')]) as api, \
                patch.object(embedded.time, 'sleep'):
            embedded.create_stable_tag('fixture', self.tag, self.sha)
        self.assertEqual(api.call_count, 2)

    def test_ref_creation_error_remains_visible_if_no_qualified_tag_appears(self):
        with patch.object(embedded, 'resolve_ref', return_value=None), \
                patch.object(embedded, 'api', side_effect=[{'sha': 'c' * 40}, GateError('HTTP403 creating ref')]), \
                patch.object(embedded.time, 'sleep'), self.assertRaisesRegex(GateError, 'HTTP403 creating ref.*preserve it'):
            embedded.create_stable_tag('fixture', self.tag, self.sha)

    def test_only_http404_is_classified_as_new_tag_visibility(self):
        for status in (404, 403, 500):
            error = urllib.error.HTTPError('https://api.github.com', status, 'fixture', None, None)
            with self.subTest(status=status), patch.object(embedded.urllib.request, 'urlopen', side_effect=error):
                with self.assertRaises(GateError) as caught:
                    embedded.api('git/tags/' + 'c' * 40, 'fixture-private-token')
                self.assertEqual(isinstance(caught.exception, embedded.QualificationNotFound), status == 404)
                self.assertIn('git/tags/', str(caught.exception))
                self.assertNotIn('fixture-private-token', str(caught.exception))

    def test_freeze_command_never_creates_a_tag_when_one_required_job_failed(self):
        environment = {'GH_TOKEN': 'fixture', 'REPOSITORY': embedded.REPOSITORY, 'COMMIT_SHA': self.sha,
                       'RELEASE_TAG': self.tag, 'CANDIDATE_REF': f'{self.tag}-candidate.{self.sha}',
                       'GITHUB_REF': 'refs/heads/main', 'GITHUB_RUN_ID': '42', 'GITHUB_RUN_ATTEMPT': '2'}
        jobs = deepcopy(self.jobs)
        jobs[0]['conclusion'] = 'failure'
        with patch.dict(os.environ, environment), patch.object(sys, 'argv', ['verify', '--create-tag']), \
                patch.object(embedded, 'verify_candidate'), patch.object(embedded, 'api', return_value=self.run), \
                patch.object(embedded, '_pages', return_value=jobs), \
                patch.object(embedded, 'create_stable_tag') as create, self.assertRaises(GateError):
            embedded.main()
        create.assert_not_called()


if __name__ == '__main__':
    unittest.main()
