"""Exercise direct and private-proxy FFmpeg source download routing."""

import hashlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import prepare_android_ffmpeg_source as ffmpeg_source


class Response(io.BytesIO):
    def __init__(self, url: str, payload: bytes):
        super().__init__(payload)
        self.url = url

    def geturl(self) -> str:
        return self.url


class Opener:
    def __init__(self, response: Response):
        self.response = response

    def open(self, request, timeout: int):
        return self.response


class AndroidFfmpegSourceTest(unittest.TestCase):
    def test_public_direct_egress_disables_environment_proxy_and_verifies_hash(self):
        url = "https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz"
        payload = b"verified FFmpeg source archive"
        opener = Opener(Response(url, payload))

        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "ffmpeg.tar.xz"
            with mock.patch.object(ffmpeg_source, "proxy_parts", side_effect=AssertionError("proxy used")):
                with mock.patch.object(ffmpeg_source, "build_opener", return_value=opener) as build_opener:
                    ffmpeg_source.download(
                        url,
                        destination,
                        hashlib.sha256(payload).hexdigest(),
                        direct_egress=True,
                    )

            self.assertEqual(build_opener.call_args.args[0].proxies, {})
            self.assertEqual(destination.read_bytes(), payload)

    def test_private_route_still_requires_the_jit_proxy(self):
        url = "https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz"
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "ffmpeg.tar.xz"
            with mock.patch.object(ffmpeg_source, "proxy_parts", side_effect=ValueError("proxy required")):
                with self.assertRaisesRegex(ValueError, "proxy required"):
                    ffmpeg_source.download(url, destination, "0" * 64)


if __name__ == "__main__":
    unittest.main()
