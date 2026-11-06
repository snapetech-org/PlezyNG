from fractions import Fraction
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from companion import bake_script, bundled_worker_environment, encode_command, pipe_processes, probe, validate_shape
from unittest.mock import patch


class CompanionTest(unittest.TestCase):
    def test_bundled_worker_does_not_load_python_libraries_into_the_host_shell(self):
        inherited = {'PATH': '/usr/bin', 'LANG': 'en_US.UTF-8', 'LD_LIBRARY_PATH': '/old/python/libs',
                     'LD_PRELOAD': '/old/overlay.so', 'PYTHONHOME': '/old/python', 'PYTHONPATH': '/old/modules'}
        with patch.dict(os.environ, inherited, clear=True):
            self.assertEqual(bundled_worker_environment(), {'PATH': '/usr/bin', 'LANG': 'en_US.UTF-8'})
            self.assertEqual(os.environ['LD_LIBRARY_PATH'], '/old/python/libs')

    @unittest.skipUnless(os.name == 'posix', 'GUI cancellation uses POSIX SIGINT on Linux')
    def test_gui_cancellation_reaps_both_pipeline_workers(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            worker = "import os,sys,time; from pathlib import Path; Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(30)"
            runner = (f"import sys; from pathlib import Path; sys.path.insert(0, {str(Path(__file__).parent)!r}); "
                      "from companion import pipe_processes; "
                      f"pipe_processes([sys.executable, '-c', {worker!r}, 'producer.pid'], "
                      f"[sys.executable, '-c', {worker!r}, 'encoder.pid'], timeout=35, cwd=Path('.'))")
            process = subprocess.Popen([sys.executable, '-c', runner], cwd=work,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            pids = []
            try:
                deadline = time.monotonic() + 5
                while not all((work / name).exists() for name in ('producer.pid', 'encoder.pid')):
                    if time.monotonic() > deadline:
                        self.fail('pipeline workers did not start')
                    time.sleep(0.01)
                pids = [int((work / name).read_text()) for name in ('producer.pid', 'encoder.pid')]
                process.send_signal(signal.SIGINT)
                process.communicate(timeout=5)
                self.assertNotEqual(process.returncode, 0)
                for pid in pids:
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)
                pids = []
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
                for pid in pids:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_shape_rejects_incompatible_or_unbounded_layers(self):
        bl = dict(codec_name="hevc", width=3840, height=2160, pix_fmt="yuv420p10le")
        el = {**bl, "width": 1920, "height": 1080}
        self.assertEqual(validate_shape(bl, el), (3840, 2160))
        for invalid in ({**el, "width": 1280}, {**el, "pix_fmt": "nv12"}, {**el, "codec_name": "h264"}):
            with self.assertRaises(ValueError):
                validate_shape(bl, invalid)
        with self.assertRaises(ValueError):
            validate_shape({**bl, "width": 999999}, el)

    def test_paths_are_data_not_python_or_shell(self):
        odd = Path("odd'\\name\n$(id);file.hevc")
        script = bake_script(odd, odd, odd, odd, Fraction(24000, 1001), 12)
        compile(script, "bake.vpy", "exec")
        self.assertIn("core.fel.Bake(bl, el", script)
        self.assertIn("bl.num_frames != el.num_frames", script)
        args = encode_command(Path("ffmpeg"), odd, width=32, height=32, fps=Fraction(24),
                              target="hdr10", peak_nits=1000, frames=12)
        self.assertEqual(args[-1], str(odd))
        self.assertIn("-n", args)
        self.assertNotIn("copy", args)

    def test_failed_producer_and_timeout_never_count_as_success(self):
        with tempfile.TemporaryDirectory() as work:
            with self.assertRaises(RuntimeError):
                pipe_processes([sys.executable, "-c", "raise SystemExit(3)"],
                               [sys.executable, "-c", "import sys; sys.stdin.buffer.read()"],
                               timeout=5, cwd=Path(work))
            with self.assertRaises(subprocess.TimeoutExpired):
                pipe_processes([sys.executable, "-c", "import time; time.sleep(10)"],
                               [sys.executable, "-c", "import sys; sys.stdin.buffer.read()"],
                               timeout=0.1, cwd=Path(work))

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg tools unavailable")
    def test_actual_hdr_and_sdr_encoding_and_color_tags(self):
        # Tests encoding/presentation carriage, not FEL reconstruction. A tiny
        # PQ RGB ramp is supplied directly; no FEL media or fake decoder claim.
        ffmpeg, ffprobe = Path(shutil.which("ffmpeg")), Path(shutil.which("ffprobe"))
        filters = subprocess.run([str(ffmpeg), "-hide_banner", "-filters"], capture_output=True, text=True, check=True).stdout
        encoders = subprocess.run([str(ffmpeg), "-hide_banner", "-encoders"], capture_output=True, text=True, check=True).stdout
        if "zscale" not in filters or "libx265" not in encoders or "libx264" not in encoders:
            self.skipTest("zscale/x264/x265 unavailable")
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            raw = work / "ramp.raw"
            plane = b"".join(int(x * 65535 / 31).to_bytes(2, "little") for _ in range(32) for x in range(32))
            raw.write_bytes(plane * 3 * 3)
            for target in ("hdr10", "sdr"):
                output = work / (target + ".mkv")
                command = encode_command(ffmpeg, output, width=32, height=32, fps=Fraction(24),
                                         target=target, peak_nits=1000, frames=3)
                producer = [sys.executable, "-c", "import sys; sys.stdout.buffer.write(open(sys.argv[1], 'rb').read())", str(raw)]
                pipe_processes(producer, command, timeout=30, cwd=work)
                info = probe(ffprobe, output)
                self.assertEqual(info["color_transfer"], "smpte2084" if target == "hdr10" else "bt709")
                self.assertEqual(info["pix_fmt"], "yuv420p10le" if target == "hdr10" else "yuv420p")


if __name__ == "__main__":
    unittest.main()
