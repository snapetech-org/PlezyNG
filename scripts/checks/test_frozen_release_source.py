"""An advancing main cannot change an already frozen release or its CI identity."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import release_all_platforms as release
import verify_release_ci as ci


class FrozenSourceTests(unittest.TestCase):
    sha = 'a' * 40
    tag = 'v3.0.30'

    def test_annotated_tag_can_remain_valid_after_main_advances(self):
        with patch.object(release, 'gh_json', side_effect=[
            {'object': {'type': 'tag', 'sha': 'b' * 40}},
            {'object': {'type': 'commit', 'sha': self.sha}},
            {'status': 'ahead', 'base_commit': {'sha': self.sha}},
        ]):
            release.ensure_frozen_release_source(self.tag, self.sha)

    def test_changed_tag_and_noncanonical_ancestry_are_rejected(self):
        for answers in ([{'object': {'type': 'commit', 'sha': 'b' * 40}}],
                        [{'object': {'type': 'commit', 'sha': self.sha}},
                         {'status': 'diverged', 'base_commit': {'sha': self.sha}}]):
            with self.subTest(answers=answers), patch.object(release, 'gh_json', side_effect=answers), \
                    self.assertRaises(release.ReleaseError):
                release.ensure_frozen_release_source(self.tag, self.sha)

    def test_ci_reuses_only_the_frozen_tag_and_exact_sha(self):
        run = {'databaseId': 42, 'status': 'completed', 'conclusion': 'success'}
        with patch.object(release, 'ensure_frozen_release_source') as identity, \
                patch.object(release, 'matching_run', return_value=run) as matching, \
                patch.object(release, 'run_has_successful_job', return_value=True), \
                patch.object(release, 'dispatch') as dispatch:
            self.assertEqual(release.ensure_ci(self.sha, source_ref=self.tag), run)
        identity.assert_called_once_with(self.tag, self.sha)
        self.assertEqual(matching.call_args.kwargs['ref'], self.tag)
        dispatch.assert_not_called()

    def test_ci_gate_requires_the_explicit_tag_not_another_branch_at_same_sha(self):
        gate = ci._manifest_gate()
        valid = {'head_sha': self.sha, 'head_branch': self.tag, 'event': 'workflow_dispatch', 'id': 42}
        answers = [{'object': {'type': 'commit', 'sha': self.sha}},
                   {'status': 'ahead', 'base_commit': {'sha': self.sha}}]
        with patch.dict(os.environ, {'RELEASE_TAG': self.tag}), \
                patch.object(ci, '_request_json', side_effect=answers), \
                patch.object(ci, '_pages', return_value=[{**valid, 'head_branch': 'untrusted'}, valid]) as pages:
            self.assertEqual(ci._latest_run('fixture', release.PLEZY_REPO, self.sha, gate), valid)
        self.assertIn('branch=v3.0.30', pages.call_args.args[0])

    def test_ci_gate_rejects_a_retargeted_tag_before_examining_runs(self):
        with patch.dict(os.environ, {'RELEASE_TAG': self.tag}), \
                patch.object(ci, '_request_json', return_value={'object': {'type': 'commit', 'sha': 'b' * 40}}), \
                patch.object(ci, '_pages') as pages, self.assertRaises(ci.GateError):
            ci._latest_run('fixture', release.PLEZY_REPO, self.sha, ci._manifest_gate())
        pages.assert_not_called()

    def test_wrong_source_version_fails_before_native_preparation_or_pin_push(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(sys, 'argv', ['release', '--version', '3.0.30', '--scratch', directory]), \
                patch.object(release, 'existing_release_tag_commit', return_value=None), \
                patch.object(release, 'create_plezy_worktree', return_value=Path(directory) / 'product'), \
                patch.object(release, 'command', side_effect=lambda args, **kwargs:
                    subprocess.CompletedProcess(args, 0, '3.0.31', '')), \
                patch.object(release, 'prepare_native_checkout') as native, \
                patch.object(release, 'commit_and_push_native_pin') as push, \
                self.assertRaisesRegex(release.ReleaseError, 'selected source declares 3.0.31'):
            release.main()
        native.assert_not_called()
        push.assert_not_called()

    def test_metadata_failure_retains_outputs_before_removing_only_its_worktree(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            checkout = scratch / 'published-facts'
            checkout.mkdir()
            (checkout / 'README.md').write_text('retained publication facts')
            with patch.object(release, 'ensure_frozen_release_source'), \
                    patch.object(release, 'command', return_value=subprocess.CompletedProcess([], 0, self.sha, '')) as command, \
                    patch.object(release, 'refresh_published_facts', side_effect=release.ReleaseError('push raced main')), \
                    self.assertRaisesRegex(release.ReleaseError, 'push raced main'):
                release.refresh_latest_published_facts(scratch, self.tag, self.sha)
            self.assertEqual((scratch / 'published-facts-evidence/README.md').read_text(), 'retained publication facts')
            self.assertTrue((scratch / 'published-facts-evidence/retry.json').exists())
            self.assertEqual(command.call_args.args[0], ['git', 'worktree', 'remove', '--force', checkout])


if __name__ == '__main__':
    unittest.main()
