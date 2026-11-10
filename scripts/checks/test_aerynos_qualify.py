"""Check native QA measurements against known clocks and authored PCM payloads."""
import importlib.util
from pathlib import Path
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'aerynos'))
from qualify import AppQA


class PlaybackMeasurementsTests(unittest.TestCase):
    def test_clock_reads_elapsed_time_from_merged_semantics(self):
        app = AppQA.__new__(AppQA)
        app.ui = lambda *args: [{'name': 'Maestro Movie\n3m\n4:30 AM\n0:15\n-2:45'}]
        self.assertEqual(app.clock(), 15)
        app.ui = lambda *args: [{'name': 'Maestro Movie\n4:30 AM\n-2:45'}]
        with self.assertRaises(RuntimeError):
            app.clock()

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
            measured = app.audio_since(44)
            self.assertAlmostEqual(measured['peak_frequency_hz'], 440, delta=1)
            self.assertGreater(measured['rms'], 900)
            paused = app.audio_since(44 + len(signal))
            self.assertEqual(paused['frames'], rate)
            self.assertEqual(paused['rms'], 0)
            self.assertIsNone(paused['peak_frequency_hz'])
            path.write_bytes(b'invalid capture')
            with self.assertRaises(RuntimeError):
                app.audio_since(44)


if __name__ == '__main__':
    unittest.main()
