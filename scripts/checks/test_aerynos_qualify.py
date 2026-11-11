"""Check native QA measurements against known clocks and authored PCM payloads."""
import importlib.util
import json
from pathlib import Path
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'aerynos'))
from qualify import AppQA, capture_audio


class PlaybackMeasurementsTests(unittest.TestCase):
    def test_search_navigation_does_not_require_an_offscreen_floating_header(self):
        with tempfile.TemporaryDirectory() as directory:
            app = AppQA.__new__(AppQA)
            app.evidence = Path(directory)
            calls = []
            def ui(*args):
                calls.append(args)
                return [{'name': 'Search', 'role': 'push button'},
                        {'name': 'Maestro Movie', 'role': 'text'}]
            app.ui = ui
            app.open_search()
            self.assertEqual(calls[0], ('click', 'Search'))
            self.assertTrue((app.evidence / 'search-ready.json').exists())

    def test_search_requires_one_editable_field_and_retains_failure_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            app = AppQA.__new__(AppQA)
            app.evidence = Path(directory)
            app.guest = SimpleNamespace(screenshot=lambda path: path.write_bytes(b'fixture screenshot'))
            for fields in ([], [{'name': '', 'role': 'text'}] * 2):
                app.ui = lambda *args: [{'name': 'Search', 'role': 'header'}, *fields]
                with self.subTest(fields=fields), self.assertRaises(RuntimeError):
                    app.open_search(timeout=0)
            self.assertTrue((app.evidence / 'search-timeout.json').exists())
            self.assertTrue((app.evidence / 'search-timeout.png').exists())

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
