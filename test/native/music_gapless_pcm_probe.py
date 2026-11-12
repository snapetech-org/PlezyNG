#!/usr/bin/env python3
"""Exercise actual libmpv gapless output with generated stereo codec fixtures.

Requires a prepared native library and ffmpeg; never downloads a dependency.
File-output evidence does not qualify speakers, device latency or app lifecycle.
"""
import argparse
import ctypes as c
import hashlib
import json
import math
from pathlib import Path
import platform
import struct
import subprocess
import tempfile
import time
import wave

if not __debug__:
    raise RuntimeError('Run this qualification with Python assertions enabled')
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--library', required=True, type=Path)
parser.add_argument('--output-dir', required=True, type=Path)
parser.add_argument('--expected-sha256', required=True)
args = parser.parse_args()
library = args.library.resolve(strict=True)
library_sha = hashlib.sha256(library.read_bytes()).hexdigest()
if library_sha != args.expected_sha256.lower():
    raise RuntimeError('Prepared native library checksum does not match the requested pin')
args.output_dir.mkdir(parents=True, exist_ok=True)
out = Path(tempfile.mkdtemp(prefix='music-gapless-', dir=args.output_dir))
lib = c.CDLL(str(library))
lib.mpv_create.restype = c.c_void_p
lib.mpv_initialize.argtypes = [c.c_void_p]
lib.mpv_set_option_string.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
lib.mpv_command.argtypes = [c.c_void_p, c.POINTER(c.c_char_p)]
lib.mpv_get_property.argtypes = [c.c_void_p, c.c_char_p, c.c_int, c.c_void_p]
lib.mpv_terminate_destroy.argtypes = [c.c_void_p]

rate, frames = 48000, 24000
samples = [round(.2 * 32767 * math.sin(.371 + 2 * math.pi * (400 * i / rate + 200 * (i / rate) ** 2)))
           for i in range(frames * 2)]
for index in (0, 1):
    path = out / f'part-{index}.wav'
    with wave.open(str(path), 'wb') as stream:
        stream.setnchannels(2)
        stream.setsampwidth(2)
        stream.setframerate(rate)
        stream.writeframes(b''.join(struct.pack('<hh', value, -value) for value in samples[index * frames:(index + 1) * frames]))
    for extension, codec in [('flac', 'flac'), ('mp3', 'libmp3lame'), ('alac.m4a', 'alac'), ('aac.m4a', 'aac'), ('opus.ogg', 'libopus')]:
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin', '-y',
                        '-i', str(path), '-c:a', codec, str(path.with_suffix('.' + extension))], check=True, timeout=30)

def pcm(path):
    if path.stat().st_size > 8 * 1024 * 1024:
        raise RuntimeError('Unbounded native PCM output')
    data, pos, fmt, payload = path.read_bytes(), 12, None, None
    while pos + 8 <= len(data):
        tag, size = struct.unpack_from('<4sI', data, pos)
        chunk = data[pos + 8:pos + 8 + size]
        if tag == b'fmt ':
            fmt = chunk
        elif tag == b'data':
            payload = chunk
        pos += 8 + size + (size & 1)
    assert fmt is not None and payload is not None, 'Missing PCM chunks'
    encoding, channels, frequency = struct.unpack_from('<HHI', fmt)
    bits = struct.unpack_from('<H', fmt, 14)[0]
    if encoding == 65534:
        encoding = struct.unpack_from('<H', fmt, 24)[0]
    assert (encoding, bits, channels, frequency) == (3, 32, 2, rate), (encoding, bits, channels, frequency)
    return struct.unpack('<' + 'f' * (len(payload) // 4), payload)

results = []
for first, second in [('wav', 'wav'), ('flac', 'flac'), ('mp3', 'mp3'), ('flac', 'wav'), ('alac.m4a', 'alac.m4a'), ('aac.m4a', 'aac.m4a'), ('opus.ogg', 'opus.ogg')]:
    target = out / f'{first}-{second}.wav'
    ctx = lib.mpv_create()
    if not ctx:
        raise RuntimeError('Native audio core allocation failed')
    try:
        for key, value in {'config': 'no', 'terminal': 'no', 'vo': 'null', 'ao': 'pcm',
                           'ao-pcm-file': str(target), 'audio-display': 'no', 'audio-format': 'float',
                           'audio-samplerate': str(rate), 'gapless-audio': 'yes',
                           'prefetch-playlist': 'yes', 'idle': 'yes', 'keep-open': 'no',
                           'volume': '100', 'replaygain': 'no'}.items():
            assert lib.mpv_set_option_string(ctx, key.encode(), value.encode()) == 0, key
        assert lib.mpv_initialize(ctx) == 0
        for index, extension in enumerate((first, second)):
            args = [b'loadfile', str(out / f'part-{index}.{extension}').encode(), b'replace' if index == 0 else b'append', None]
            assert lib.mpv_command(ctx, (c.c_char_p * len(args))(*args)) == 0
        start = time.monotonic()
        while time.monotonic() - start < 4:
            time.sleep(.01)
            idle = c.c_int()
            if time.monotonic() - start > .25 and lib.mpv_get_property(ctx, b'idle-active', 3, c.byref(idle)) == 0 and idle.value:
                break
        else:
            raise AssertionError('Native playlist did not finish')
    finally:
        lib.mpv_terminate_destroy(ctx)
    rendered = pcm(target)
    assert len(rendered) == frames * 2 * 2, (first, second, len(rendered) // 2)
    before, after = frames - 1024, frames + 1024
    errors = [rendered[i * 2 + channel] - samples[i] * (1 if channel == 0 else -1) / 32768
              for i in range(before, after) for channel in (0, 1)]
    rms = math.sqrt(sum(value * value for value in errors) / len(errors))
    maximum = max(abs(value) for value in errors)
    tolerance = .02 if any(value in ('mp3', 'aac.m4a', 'opus.ogg') for value in (first, second)) else 1e-6
    assert rms < tolerance, (first, second, rms)
    results.append({'first': first, 'second': second, 'frames': len(rendered) // 2, 'rate': rate,
                    'joinWindowFrames': after - before, 'joinRmsError': rms, 'joinMaxError': maximum, 'joinRmsTolerance': tolerance})
receipt = {'version': 1, 'platform': platform.platform(), 'librarySha256': library_sha,
           'encoderVersion': subprocess.check_output(['ffmpeg', '-version'], text=True, timeout=5).splitlines()[0],
           'generatedFixture': '48 kHz stereo chirp, opposite channels, two 24000-frame tracks',
           'outputDirectory': str(out.resolve()), 'fixtures': results}
report = json.dumps(receipt, indent=2) + '\n'
(out / 'receipt.json').write_text(report)
print(report, end='')
