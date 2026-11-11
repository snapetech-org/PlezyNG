"""Check native QA measurements against known clocks and authored PCM payloads."""
import importlib.util
import hashlib
import json
from pathlib import Path
import struct
import shlex
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
import urllib.parse
from unittest.mock import Mock, call, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'aerynos'))
from qualify import AppQA, capture_audio, check_playback_routes


class PlaybackMeasurementsTests(unittest.TestCase):
    def test_direct_fixture_serves_scratch_input_and_retains_evidence_in_distinct_output(self):
        import urllib.request
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scratch, output = root / 'scratch', root / 'output'
            relative = Path('jellyfin/media/movies/maestro-movie/Maestro Movie.mp4')
            for base, content in ((scratch, b'authored scratch fixture'), (output, b'wrong output decoy')):
                (base / relative).parent.mkdir(parents=True)
                (base / relative).write_bytes(content)
            evidence = output / 'evidence'
            evidence.mkdir()
            calls = []
            def direct(server_port):
                calls.append('direct')
                with urllib.request.urlopen(f'http://127.0.0.1:{server_port}/Maestro%20Movie.mp4', timeout=5) as response:
                    self.assertEqual(response.read(), b'authored scratch fixture')
            app = SimpleNamespace(evidence=evidence,
                verify_default=lambda: calls.append('defaults'), visible_h264=lambda: calls.append('server-video'),
                lifecycle=lambda: calls.append('server-lifecycle'), direct_playback=direct)
            with patch('qualify.http.server.SimpleHTTPRequestHandler.log_message'):
                check_playback_routes(app, scratch)
            self.assertEqual(calls, ['defaults', 'server-video', 'server-lifecycle', 'direct'])
            receipt = json.loads((evidence / 'open-media-fixture.json').read_text())
            self.assertEqual(receipt['sha256'], hashlib.sha256(b'authored scratch fixture').hexdigest())
            self.assertFalse((scratch / 'evidence').exists())

    def test_source_clock_is_bounded_by_position_slider_and_remaining_text(self):
        with tempfile.TemporaryDirectory() as directory:
            app = AppQA.__new__(AppQA)
            app.evidence = Path(directory)
            app.ui = Mock(return_value=[{'name': '0:01', 'role': 'panel'},
                {'name': 'Position', 'role': 'slider'}, {'name': '', 'role': 'panel'},
                {'name': '0:59', 'role': 'panel'}, {'name': 'Time remaining in this chapter: 2:00', 'role': 'panel'},
                {'name': '2:00 remaining', 'role': 'panel'}, {'name': '0:02', 'role': 'panel'}])
            self.assertEqual(app.source_clock(timeout=0), 59)

    def test_source_clock_rejects_missing_ambiguous_or_invalid_player_clock(self):
        position = {'name': 'Position', 'role': 'slider'}
        elapsed, remaining = {'name': '0:59', 'role': 'panel'}, {'name': '2:00 remaining', 'role': 'panel'}
        for nodes in ([elapsed, remaining], [position, position, elapsed, remaining],
                      [position, elapsed, elapsed, remaining], [position, elapsed],
                      [position, remaining], [position, {'name': '0:99', 'role': 'panel'}, remaining]):
            with self.subTest(nodes=nodes), tempfile.TemporaryDirectory() as directory:
                app = AppQA.__new__(AppQA)
                app.evidence = Path(directory)
                app.ui = Mock(return_value=nodes)
                with self.assertRaisesRegex(RuntimeError, 'unique Open media elapsed clock'):
                    app.source_clock(timeout=0)
                self.assertEqual(json.loads((app.evidence / 'source-clock-timeout.json').read_text()), nodes)

    def direct_app(self, directory, *, ignore_consent=None, observation_error=None):
        app = AppQA.__new__(AppQA)
        app.evidence = Path(directory)
        app.guest = SimpleNamespace(user=Mock())
        app.stop, app.launch = Mock(), Mock()
        app.wait = Mock()
        app.form_field = Mock()
        app.observe_playback = Mock(side_effect=observation_error)
        state = {'Allow an unencrypted HTTP connection': False, 'Treat as live': True}
        events = []
        def ui(action, name, value=None):
            events.append((action, name, value))
            if action == 'state': return state[name]
            if action == 'click' and name in state and name != ignore_consent:
                state[name] = not state[name]
        app.ui = Mock(side_effect=ui)
        return app, events

    def test_direct_route_uses_normal_uri_and_stream_consent_before_untouched_first_frame_observation(self):
        with tempfile.TemporaryDirectory() as directory:
            app, events = self.direct_app(directory)
            def observe(*args, **kwargs):
                self.assertEqual(events[-1], ('click', 'Play now', None))
                self.assertFalse(any('seek' in name.lower() or 'fullscreen' in name.lower()
                                     or name in ('Pause', 'Back') for _, name, _ in events))
            app.observe_playback.side_effect = observe
            app.direct_playback(12345)
            app.stop.assert_called_once_with()
            app.launch.assert_called_once()
            app.guest.user.assert_not_called()
            link = urllib.parse.urlsplit(app.launch.call_args.kwargs['link'])
            self.assertEqual((link.scheme, link.netloc), ('pleazyng', 'open-media'))
            self.assertEqual(urllib.parse.parse_qs(link.query)['url'],
                             ['https://10.0.2.2:12345/Maestro%20Movie.mp4'])
            self.assertEqual(app.form_field.call_args_list, [
                call('Media address', 'http://10.0.2.2:12345/Maestro%20Movie.mp4'),
                call('Display name (optional)', 'QA direct H264')])
            app.observe_playback.assert_called_once_with('open-media-initial', source_route=True)
            self.assertEqual(events[-1], ('click', 'Back', None))

    def test_native_form_entry_types_scheme_punctuation_and_case_then_checks_value(self):
        app = AppQA.__new__(AppQA)
        app.pointer_field, app.key = Mock(), Mock()
        value = 'http://10.0.2.2:12345/Maestro%20Movie.mp4'
        app.ui = Mock(return_value=value)
        with patch('qualify.time.sleep'):
            app.form_field('Media address', value)
        app.pointer_field.assert_called_once_with('Media address', placeholder=False)
        self.assertEqual(app.key.call_args_list[:8], [call(key) for key in
            ('ctrl-a', 'h', 't', 't', 'p', 'shift-semicolon', 'slash', 'slash')])
        self.assertIn(call('shift-m'), app.key.call_args_list)
        self.assertIn(call('shift-5'), app.key.call_args_list)
        app.ui.assert_called_once_with('form-text', 'Media address')

    def test_native_form_entry_rejects_unchanged_https_before_consent_or_play(self):
        with tempfile.TemporaryDirectory() as directory:
            app, events = self.direct_app(directory)
            del app.form_field
            app.pointer_field, app.key = Mock(), Mock()
            original = app.ui
            app.ui = Mock(side_effect=lambda action, name, value=None:
                'https://10.0.2.2:12345/Maestro%20Movie.mp4' if action == 'form-text'
                else original(action, name, value))
            app.guest.screenshot = Mock()
            with patch('qualify.time.sleep'), patch('qualify.time.monotonic', side_effect=[0, 6]):
                with self.assertRaisesRegex(RuntimeError, 'did not retain authored input'):
                    app.direct_playback(12345)
            self.assertFalse(events)
            app.observe_playback.assert_not_called()
            app.guest.screenshot.assert_called_once_with(app.evidence / 'form-input-failed.png')

    def test_native_form_entry_rejects_other_fields_and_unsupported_input_before_focus(self):
        app = AppQA.__new__(AppQA)
        app.pointer_field, app.key = Mock(), Mock()
        for label, value in (('Password', 'maestro'), ('Media address', 'http://bad\n'),
                             ('Display name (optional)', ''), ('Media address', 'é')):
            with self.subTest(label=label, value=value), self.assertRaises(ValueError):
                app.form_field(label, value)
        app.pointer_field.assert_not_called()
        app.key.assert_not_called()

    def test_pointer_field_matches_multiword_label_within_one_observed_ocr_line(self):
        app = AppQA.__new__(AppQA)
        app.evidence = Path('/fixture-evidence')
        app.guest = SimpleNamespace(screenshot=Mock())
        app.click = Mock()
        header = 'page_num\tblock_num\tpar_num\tline_num\tleft\ttop\twidth\theight\ttext\n'
        rows = '1\t1\t1\t1\t100\t200\t40\t14\tMedia\n1\t1\t1\t1\t150\t200\t60\t14\taddress\n'
        with patch('qualify.run', return_value=SimpleNamespace(stdout=header + rows)):
            app.pointer_field('Media address')
        app.click.assert_called_once_with(155, 226)
        app.click.reset_mock()
        with patch('qualify.run', return_value=SimpleNamespace(stdout=header + rows)):
            app.pointer_field('Media address', placeholder=True)
        app.click.assert_called_once_with(155, 207)
        for extra in (rows, rows.replace('\t1\t150', '\t2\t150')):
            # Duplicate labels or words split across lines must not select a field.
            data = rows + extra if extra == rows else extra
            with patch('qualify.run', return_value=SimpleNamespace(stdout=header + data)):
                with self.assertRaisesRegex(RuntimeError, 'Could not locate'):
                    app.pointer_field('Media address')

    def test_link_launch_keeps_one_owned_unit_and_does_not_dismiss_the_open_media_form(self):
        app = AppQA.__new__(AppQA)
        app.guest = SimpleNamespace(user=Mock())
        app.key = Mock()
        link = 'pleazyng://open-media?url=https%3A%2F%2Fexample.invalid%2Ffixture.mp4'
        with patch('qualify.time.sleep'):
            app.launch(link=link)
        argv = shlex.split(app.guest.user.call_args.args[0])
        self.assertEqual(argv, ['systemd-run', '--user', '--unit=pleazyng-qa', '/usr/bin/pleazyng', link])
        app.key.assert_called_once_with('alt-f10')

    def test_direct_route_cannot_play_without_http_consent_or_with_live_mode_left_on(self):
        for ignored in ('Allow an unencrypted HTTP connection', 'Treat as live'):
            with self.subTest(ignored=ignored), tempfile.TemporaryDirectory() as directory:
                app, events = self.direct_app(directory, ignore_consent=ignored)
                with self.assertRaises(RuntimeError):
                    app.direct_playback(12345)
                self.assertNotIn(('click', 'Play now', None), events)
                app.observe_playback.assert_not_called()

    def test_failed_direct_observation_keeps_failure_on_the_player_route(self):
        with tempfile.TemporaryDirectory() as directory:
            app, events = self.direct_app(directory, observation_error=RuntimeError('black first frame'))
            with self.assertRaisesRegex(RuntimeError, 'black first frame'):
                app.direct_playback(12345)
            self.assertEqual(events[-1], ('click', 'Play now', None))

    @unittest.skipUnless(importlib.util.find_spec('PIL'), 'Pillow required for video measurements')
    def test_direct_observation_rejects_black_or_frozen_video_despite_advancing_clock_and_audio(self):
        from PIL import Image
        for colors, failure in ((('red', 'lime'), None), (('black', 'black'), 'not visible'),
                                (('red', 'red'), 'moving video')):
            with self.subTest(colors=colors), tempfile.TemporaryDirectory() as directory:
                app = AppQA.__new__(AppQA)
                app.evidence = Path(directory)
                (app.evidence / 'audio.wav').write_bytes(bytes(44))
                palette = iter(colors)
                def screenshot(path):
                    Image.new('RGB', (1280, 800), next(palette)).save(path)
                app.guest = SimpleNamespace(root=app.evidence, screenshot=screenshot)
                app.source_clock = Mock(side_effect=[10, 14])
                app.controls, app.hide_controls, app.clock, app.ui = Mock(), Mock(), Mock(), Mock()
                app.audio_since = Mock(return_value={'rms': 2000, 'peak_frequency_hz': 440})
                with patch('qualify.time.sleep'):
                    if failure:
                        with self.assertRaisesRegex(RuntimeError, failure):
                            app.observe_playback('direct', source_route=True)
                    else:
                        app.observe_playback('direct', source_route=True)
                for control in (app.controls, app.hide_controls, app.clock, app.ui):
                    control.assert_not_called()
                measured = json.loads((app.evidence / 'direct.json').read_text())
                self.assertEqual(measured['route'], 'open-media')
                self.assertEqual(measured['clock_after'], 14)
                self.assertEqual(measured['audio']['peak_frequency_hz'], 440)

    def test_hide_controls_clicks_visible_controls_without_an_extra_tree_read(self):
        app = AppQA.__new__(AppQA)
        app.ui = Mock(return_value=True)
        app.hide_controls()
        app.ui.assert_called_once_with('click', 'Hide playback controls')

    def test_hide_controls_accepts_only_fresh_confirmed_auto_hide_after_click_failure(self):
        app = AppQA.__new__(AppQA)
        failure = subprocess.CalledProcessError(1, ['qa-ui', 'click'])
        app.ui = Mock(side_effect=[failure, [{'name': 'Show playback controls'}]])
        app.hide_controls()
        self.assertEqual(app.ui.call_args_list, [call('click', 'Hide playback controls'), call()])

    def test_hide_controls_preserves_failure_when_hidden_state_is_not_confirmed(self):
        for nodes in ([], [{'name': 'Hide playback controls'}],
                      [{'name': 'Show playback controls'}, {'name': 'Hide playback controls'}],
                      [{'name': 'Back'}]):
            with self.subTest(nodes=nodes):
                app = AppQA.__new__(AppQA)
                failure = subprocess.CalledProcessError(1, ['qa-ui', 'click'])
                app.ui = Mock(side_effect=[failure, nodes])
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    app.hide_controls()
                self.assertIs(raised.exception, failure)

    def test_hide_controls_does_not_swallow_other_click_or_fresh_tree_errors(self):
        for failure in (ValueError('invalid response'), json.JSONDecodeError('invalid JSON', '', 0)):
            with self.subTest(failure=type(failure).__name__):
                app = AppQA.__new__(AppQA)
                app.ui = Mock(side_effect=failure)
                with self.assertRaises(type(failure)) as raised:
                    app.hide_controls()
                self.assertIs(raised.exception, failure)
                app.ui.assert_called_once()
        app = AppQA.__new__(AppQA)
        failure = subprocess.CalledProcessError(1, ['qa-ui', 'dump'])
        app.ui = Mock(side_effect=[subprocess.CalledProcessError(1, ['qa-ui', 'click']), failure])
        with self.assertRaises(subprocess.CalledProcessError) as raised:
            app.hide_controls()
        self.assertIs(raised.exception, failure)

    @unittest.skipUnless(importlib.util.find_spec('PIL'), 'Pillow required for video measurements')
    def test_auto_hide_recovery_still_measures_and_rejects_failed_playback(self):
        from PIL import Image
        for defect, after, moving, rms, frequency in (
                (None, 14, True, 2000, 440), ('clock', 10, True, 2000, 440),
                ('motion', 14, False, 2000, 440), ('silence', 14, True, 0, None),
                ('wrong audio', 14, True, 2000, 880)):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as directory:
                app = AppQA.__new__(AppQA)
                app.evidence = Path(directory)
                (app.evidence / 'audio.wav').write_bytes(bytes(44))
                colors = iter(('red', 'lime' if moving else 'red'))
                def screenshot(path):
                    Image.new('RGB', (1280, 800), next(colors)).save(path)
                app.guest = SimpleNamespace(root=app.evidence, screenshot=screenshot)
                app.controls = Mock(return_value={'Pause'})
                app.clock = Mock(side_effect=[10, after])
                app.ui = Mock(side_effect=[subprocess.CalledProcessError(1, ['qa-ui', 'click']),
                                           [{'name': 'Show playback controls'}]])
                app.audio_since = Mock(return_value={'rms': rms, 'peak_frequency_hz': frequency})
                with patch('qualify.time.sleep'):
                    if defect:
                        with self.assertRaisesRegex(RuntimeError, 'moving video, advancing clock and authored audio'):
                            app.observe_playback('auto-hide')
                    else:
                        app.observe_playback('auto-hide')
                measured = json.loads((app.evidence / 'auto-hide.json').read_text())
                self.assertEqual(measured['clock_after'], after)
                self.assertEqual(measured['audio']['rms'], rms)
                app.audio_since.assert_called_once_with(44)

    def test_search_navigation_does_not_require_an_offscreen_floating_header(self):
        with tempfile.TemporaryDirectory() as directory:
            app = AppQA.__new__(AppQA)
            app.evidence = Path(directory)
            app.guest = SimpleNamespace(qmp=Mock())
            calls = []
            def ui(*args):
                calls.append(args)
                return [{'name': 'Search', 'role': 'push button'},
                        {'name': 'Maestro Movie', 'role': 'text'}]
            app.ui = ui
            app.open_search()
            app.guest.qmp.assert_called_once_with('human-monitor-command', {'command-line': 'sendkey ctrl-f'})
            self.assertEqual(calls, [()])
            self.assertTrue((app.evidence / 'search-ready.json').exists())

    def test_search_requires_one_editable_field_and_retains_failure_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            app = AppQA.__new__(AppQA)
            app.evidence = Path(directory)
            app.guest = SimpleNamespace(qmp=Mock(), screenshot=lambda path: path.write_bytes(b'fixture screenshot'))
            for fields in ([], [{'name': '', 'role': 'text'}] * 2):
                app.ui = lambda *args: [{'name': 'Search', 'role': 'header'}, *fields]
                with self.subTest(fields=fields), self.assertRaises(RuntimeError):
                    app.open_search(timeout=0)
            self.assertTrue((app.evidence / 'search-timeout.json').exists())
            self.assertTrue((app.evidence / 'search-timeout.png').exists())

    def test_search_shortcut_waits_for_the_input_to_arrive_on_a_later_frame(self):
        with tempfile.TemporaryDirectory() as directory:
            app = AppQA.__new__(AppQA)
            app.evidence = Path(directory)
            app.guest = SimpleNamespace(qmp=Mock())
            app.ui = Mock(side_effect=[[{'name': 'Search', 'role': 'panel'}],
                                       [{'name': 'Search query', 'role': 'text'}]])
            with patch('qualify.time.sleep') as sleep:
                app.open_search()
            sleep.assert_called_once_with(0.25)
            self.assertEqual(app.ui.call_count, 2)
            app.guest.qmp.assert_called_once()
            self.assertEqual(json.loads((app.evidence / 'search-ready.json').read_text()),
                             [{'name': 'Search query', 'role': 'text'}])

    def test_search_shortcut_delivery_failure_cannot_qualify_a_stale_editable_field(self):
        app = AppQA.__new__(AppQA)
        failure = subprocess.CalledProcessError(1, ['qmp', 'sendkey'])
        app.guest = SimpleNamespace(qmp=Mock(side_effect=failure))
        app.ui = Mock(return_value=[{'name': 'Unrelated field', 'role': 'text'}])
        with self.assertRaises(subprocess.CalledProcessError) as raised:
            app.open_search()
        self.assertIs(raised.exception, failure)
        app.ui.assert_not_called()

    def test_clock_reads_elapsed_time_from_merged_semantics(self):
        with tempfile.TemporaryDirectory() as directory:
            app = AppQA.__new__(AppQA)
            app.evidence = Path(directory)
            app.ui = lambda *args: [{'name': 'Maestro Movie\n3m\n4:30 AM\n0:15\n-2:45'}]
            self.assertEqual(app.clock(), 15)
            app.ui = lambda *args: [{'name': 'Maestro Movie\n4:30 AM\n-2:45'}]
            with self.assertRaises(RuntimeError):
                app.clock(timeout=0)
            self.assertTrue((app.evidence / 'clock-timeout.json').exists())

    def test_clock_waits_for_elapsed_text_after_seek_overlay_transition(self):
        app = AppQA.__new__(AppQA)
        calls = 0
        def nodes(*args):
            nonlocal calls
            calls += 1
            return [{'name': '0:15\n-2:45'}] if calls > 6 else [{'name': 'Hide playback controls'}]
        app.ui = nodes
        with patch('qualify.time.sleep') as sleep:
            self.assertEqual(app.clock(), 15)
        self.assertGreaterEqual(sleep.call_count, 2)

    def test_clock_ignores_wall_clock_and_duration_around_player_time(self):
        with tempfile.TemporaryDirectory() as directory:
            app = AppQA.__new__(AppQA)
            app.evidence = Path(directory)
            for panel in ('01:25\n3:00\n2:54\n-0:05',
                          '3:00\n2:54\n-0:05\n01:25'):
                with self.subTest(panel=panel):
                    app.ui = lambda *args: [{'name': 'Maestro Movie\n' + panel},
                                            {'name': '01:24'}]
                    self.assertEqual(app.clock(timeout=0), 174)

    def test_clock_accepts_long_elapsed_times_and_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            app = AppQA.__new__(AppQA)
            app.evidence = Path(directory)
            for elapsed, seconds in (('1:02:03', 3723), ('62:03', 3723), ('0:00', 0)):
                with self.subTest(elapsed=elapsed):
                    app.ui = lambda *args: [{'name': '01:25\n' + elapsed + '\n-0:05'}]
                    self.assertEqual(app.clock(timeout=0), seconds)

    def test_clock_rejects_missing_invalid_or_ambiguous_player_time(self):
        with tempfile.TemporaryDirectory() as directory:
            app = AppQA.__new__(AppQA)
            app.evidence = Path(directory)
            for names in (['01:25'], ['01:25\n-0:05', '2:54\n-0:05'],
                          ['2:54\n-0:05\n2:54\n-0:05'],
                          ['01:25\n2:54'], ['01:25\nPause\n-0:05'],
                          ['2:99\n-0:05'], ['2:54\n-0:99'], ['-0:05']):
                nodes = [{'name': name} for name in names]
                app.ui = lambda *args: nodes
                with self.subTest(names=names):
                    with self.assertRaises(RuntimeError):
                        app.clock(timeout=0)
                    self.assertEqual(json.loads(
                        (app.evidence / 'clock-timeout.json').read_text()), nodes)

    @unittest.skipUnless(importlib.util.find_spec('numpy'), 'numpy required for PCM measurement')
    def test_live_capture_ignores_placeholder_lengths_and_respects_audio_offset(self):
        import numpy as np
        rate = 44100
        tone = (2000 * np.sin(2 * np.pi * 440 * np.arange(rate) / rate)).astype('<i2')
        signal = np.column_stack((tone, tone)).tobytes()
        silence = bytes(rate * 4)
        header = struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', 0, b'WAVE', b'fmt ', 16,
                             1, 2, rate, rate * 4, 4, 16, b'data', 0)
        with tempfile.TemporaryDirectory() as directory:
            app = AppQA.__new__(AppQA)
            app.guest = SimpleNamespace(root=Path(directory))
            path = app.guest.root / 'audio.wav'
            path.write_bytes(header + signal + silence)
            evidence = Path(directory) / 'evidence'
            evidence.mkdir()
            capture_audio(app.guest.root, evidence)
            import wave
            with wave.open(str(evidence / 'audio-playable.wav')) as playable:
                self.assertEqual(playable.getnframes(), rate * 2)
                self.assertEqual(playable.readframes(rate * 2), signal + silence)
            self.assertEqual((evidence / 'audio-original.wav').read_bytes(), header + signal + silence)
            measured = app.audio_since(44)
            self.assertAlmostEqual(measured['peak_frequency_hz'], 440, delta=1)
            self.assertGreater(measured['rms'], 900)
            paused = app.audio_since(44 + len(signal))
            self.assertEqual(paused['start_byte'], 44 + len(signal))
            self.assertEqual(paused['end_byte'], 44 + len(signal) + len(silence))
            self.assertEqual(paused['frames'], rate)
            self.assertEqual(paused['rms'], 0)
            self.assertIsNone(paused['peak_frequency_hz'])
            path.write_bytes(b'invalid capture')
            with self.assertRaises(RuntimeError):
                app.audio_since(44)


if __name__ == '__main__':
    unittest.main()
