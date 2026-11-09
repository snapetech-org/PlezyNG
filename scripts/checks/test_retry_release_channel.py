"""Channel repairs consume an immutable release and never enter the app build."""
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import retry_release_channel as retry


TAG = 'v3.0.1'
TITLE = 'action:publish-snap:pool:public:tag:v3.0.1:channel:stable'
PUBLISHED = {'tagName': TAG, 'isDraft': False, 'publishedAt': '2026-11-06T12:00:00Z',
             'url': f'https://github.com/{retry.PLEZY_REPO}/releases/tag/{TAG}'}
PREVIOUS = {'id': 10, 'event': 'workflow_dispatch', 'head_branch': 'main',
            'path': '.github/workflows/publish-snap.yml', 'display_title': TITLE,
            'status': 'completed', 'conclusion': 'failure', 'head_sha': 'a' * 40,
            'html_url': 'https://example.test/runs/10'}


class ChannelRetryTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.previous = dict(PREVIOUS)
        self.release = dict(PUBLISHED)
        self.state = {"status": "completed", "conclusion": "failure"}

    def api(self, *args):
        self.calls.append(args)
        if args[0] == 'release':
            return self.release
        if args[0] == 'api' and args[1].endswith('/actions/runs/10'):
            return self.previous
        if args[0] == 'api' and args[1].endswith('/commits/main'):
            return {'sha': 'b' * 40}
        if args[:2] == ('run', 'view'):
            return self.state
        raise AssertionError(args)

    def invoke(self, *, inputs=(), retry_failed=True, wait=False, runs=None, interrupt=False):
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(retry, 'gh_json', side_effect=self.api))
            dispatch = stack.enter_context(patch.object(retry, 'command', side_effect=KeyboardInterrupt if interrupt else None, return_value=subprocess.CompletedProcess([], 0)))
            stack.enter_context(patch.object(retry, 'workflow_runs', return_value=runs or []))
            stack.enter_context(patch.object(retry.time, 'sleep'))
            result = retry.retry(TAG, 10, list(inputs), retry_failed=retry_failed, wait=wait)
        return result, dispatch

    def test_fixed_main_publisher_reuses_original_tag_without_building(self):
        result, dispatch = self.invoke()
        command = dispatch.call_args.args[0]
        self.assertEqual(command[:4], ['gh', 'workflow', 'run', 'publish-snap.yml'])
        self.assertIn('release_tag=v3.0.1', command)
        self.assertIn('channel=stable', command)
        self.assertEqual(result['requested_publisher_sha'], 'b' * 40)
        self.assertEqual(result['release_status'], 'published')
        self.assertFalse(result['rebuild_requested'])
        self.assertEqual(dispatch.call_count, 1)
        self.assertTrue(all(call[0] in {'api', 'release'} for call in self.calls))

    def test_successful_newer_attempt_is_reused_across_publisher_revisions(self):
        runs = [{'event': 'workflow_dispatch', 'displayTitle': TITLE, 'databaseId': 20,
                 'status': 'completed', 'conclusion': 'success', 'headSha': 'c' * 40,
                 'createdAt': '2026-11-06T14:00:00Z'}]
        result, dispatch = self.invoke(runs=runs)
        self.assertTrue(result['reused'])
        self.assertEqual(result['run_id'], 20)
        dispatch.assert_not_called()

    def test_inflight_lane_is_reused_without_duplicate_dispatch(self):
        runs = [{'event': 'workflow_dispatch', 'displayTitle': TITLE, 'databaseId': 20,
                 'status': 'in_progress', 'createdAt': '2026-11-06T14:00:00Z'}]
        result, dispatch = self.invoke(runs=runs)
        self.assertEqual(result['channel_status'], 'in_progress')
        dispatch.assert_not_called()

    def test_failed_lane_needs_explicit_side_effect_review(self):
        with self.assertRaisesRegex(retry.ReleaseError, 'external side effects'):
            self.invoke(retry_failed=False)

    def test_draft_foreign_and_wrong_tag_release_are_rejected(self):
        for field, value in [('isDraft', True), ('publishedAt', None), ('tagName', 'v3.0.2'),
                             ('url', 'https://github.com/other/repo/releases/tag/v3.0.1')]:
            with self.subTest(field=field), self.assertRaises(retry.ReleaseError):
                self.release = {**PUBLISHED, field: value}
                self.invoke()

    def test_build_and_ci_workflows_never_dispatch(self):
        for name in ('build.yml', 'ci.yml', '../publish-snap.yml'):
            self.previous = {**PREVIOUS, 'path': '.github/workflows/' + name}
            with self.subTest(name=name), self.assertRaises(retry.ReleaseError):
                self.invoke()

    def test_cannot_change_release_or_lane_through_extra_inputs(self):
        for field in ('release_tag=v3.0.2', 'channel=edge', 'action=build'):
            with self.subTest(field=field), self.assertRaises(retry.ReleaseError):
                self.invoke(inputs=[field])

    def test_chocolatey_publish_mode_is_derived_from_previous_run(self):
        self.previous.update(path='.github/workflows/publish-chocolatey.yml',
                             display_title='action:publish-chocolatey:pool:public:tag:v3.0.1:publish:true')
        _, dispatch = self.invoke()
        self.assertIn('publish=true', dispatch.call_args.args[0])

    def test_automatic_discord_release_event_can_retry_on_current_main(self):
        self.previous.update(path='.github/workflows/discord-release.yml', event='release',
                             head_branch='v3.0.1', display_title='action:announce-release:pool:hosted:tag:v3.0.1')
        result, dispatch = self.invoke()
        self.assertEqual(result['workflow'], 'discord-release.yml')
        self.assertIn('action=announce-release', dispatch.call_args.args[0])
        self.assertIn('main', dispatch.call_args.args[0])

    def test_google_play_requires_explicit_safe_track_and_status(self):
        self.previous.update(path='.github/workflows/publish-app-stores.yml',
                             display_title='action:publish-app-stores:pool:public:tag:v3.0.1:channel:google-play')
        for fields in ([], ['play_track=production', 'play_release_status=completed']):
            with self.subTest(fields=fields), self.assertRaises(retry.ReleaseError):
                self.invoke(inputs=fields)
        _, dispatch = self.invoke(inputs=['play_track=alpha', 'play_release_status=completed'])
        self.assertIn('play_track=alpha', dispatch.call_args.args[0])

    def test_wait_does_not_claim_success_when_dispatched_run_is_not_visible(self):
        result, dispatch = self.invoke(wait=True)
        self.assertEqual(result['channel_status'], 'dispatched')
        self.assertIn('run not yet visible', result['watch_status'])
        self.assertNotIn('publisher_sha', result)
        self.assertEqual(dispatch.call_count, 1)

    def test_stopped_watcher_reports_live_workflow_as_in_progress(self):
        self.state = {'status': 'in_progress', 'conclusion': None}
        runs = [{'event': 'workflow_dispatch', 'displayTitle': TITLE, 'databaseId': 20,
                 'status': 'in_progress', 'createdAt': '2026-11-06T14:00:00Z'}]
        for interrupt in (False, True):
            with self.subTest(interrupt=interrupt):
                result, _ = self.invoke(runs=runs, wait=True, interrupt=interrupt)
                self.assertEqual(result['channel_status'], 'in_progress')
                self.assertEqual(result['release_status'], 'published')
                self.assertIn('watcher ended', result['watch_status'])

    def test_channel_result_is_derived_from_actual_workflow_conclusion(self):
        self.state = {'status': 'completed', 'conclusion': 'success'}
        runs = [{'event': 'workflow_dispatch', 'displayTitle': TITLE, 'databaseId': 20,
                 'status': 'in_progress', 'createdAt': '2026-11-06T14:00:00Z'}]
        result, _ = self.invoke(runs=runs, wait=True)
        self.assertEqual(result['channel_status'], 'success')
        self.assertEqual(result['workflow_conclusion'], 'success')

    def test_failed_wait_does_not_change_published_release_status(self):
        runs = [{'event': 'workflow_dispatch', 'displayTitle': TITLE, 'databaseId': 20,
                 'status': 'in_progress', 'createdAt': '2026-11-06T14:00:00Z'}]
        result, dispatch = self.invoke(runs=runs, wait=True)
        self.assertEqual(result['channel_status'], 'failed')
        self.assertEqual(result['release_status'], 'published')
        self.assertEqual(dispatch.call_args.args[0][1:3], ['run', 'watch'])
        self.assertFalse(result['rebuild_requested'])


if __name__ == '__main__':
    unittest.main()
