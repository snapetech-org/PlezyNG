"""Explicit CEA-608/708 service extraction through an installed CCExtractor.

The derivative is SRT, not an implementation of native caption windows or
roll-up/pop-on rendering. No source URLs or client-specified commands are used.
"""
from __future__ import annotations

import hashlib
import os
import re
import subprocess
import threading

from bitmap_ocr import stop

MAX_BYTES = 5 * 1024**2


def validate(value):
    kind, service = value.get('broadcastKind', 'cea708'), value.get('broadcastService', 1)
    program = value.get('broadcastProgram')
    if kind not in {'cea608', 'cea708'} or type(service) is not int or not 1 <= service <= (4 if kind == 'cea608' else 63):
        raise ValueError('invalid_broadcast_caption_service')
    if program is not None and (type(program) is not int or not 1 <= program <= 65535):
        raise ValueError('invalid_broadcast_program')
    return kind, service, program


def _capture(command, bound, seconds):
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    timer = threading.Timer(seconds, stop, (process,)); timer.daemon = True; timer.start()
    try:
        raw = process.stdout.read(bound + 1)
        if len(raw) > bound or process.wait(timeout=5): raise ValueError('broadcast_decoder_failed_or_limit')
        return raw
    finally:
        timer.cancel(); stop(process); process.wait(); process.stdout.close()


def run(folder, job, progress):
    kind, service, program = validate(job)
    executable = os.environ.get('PLEZY_CCEXTRACTOR', 'ccextractor')
    # A single service and stdout avoid decoder-derived filenames and mixing
    # separate languages into one stream. Multiprogram auto-selection is off.
    command = [executable, '--stdout', '--out', 'srt', '--utf8', '--no-bom', '--no-fontcolor',
        '--no-typesetting', '--no-levdist', '--no-teletext', '--no-codec', 'dvbsub', '--endat', '3600']
    if kind == 'cea708': command.extend(['-svc', str(service)])
    else:
        command.append('-1' if service <= 2 else '-2')
        if service in (2, 4): command.append('--cc2')
    if program is not None: command.extend(['--program-number', str(program)])
    command.append(str(folder / 'input.media'))
    progress(folder, 'Extracting the selected broadcast caption service', 0)
    raw = _capture(command, MAX_BYTES, 1800)
    text = raw.decode('utf-8-sig').replace('\r\n', '\n').replace('\r', '\n').strip()
    clock = re.compile(r'^(\d{2,}):(\d{2}):(\d{2}),(\d{3}) --> (\d{2,}):(\d{2}):(\d{2}),(\d{3})$')
    cues = []
    for block in re.split(r'\n[ \t]*\n', text):
        lines = block.split('\n')
        if len(lines) < 3 or not re.fullmatch(r'\d{1,8}', lines[0].strip()):
            raise ValueError('invalid_broadcast_srt_output')
        match = clock.fullmatch(lines[1].strip())
        if match is None: raise ValueError('invalid_broadcast_caption_clock')
        n = [int(v) for v in match.groups()]
        if any(n[i] > 59 for i in (1, 2, 5, 6)): raise ValueError('invalid_broadcast_caption_clock')
        start = ((n[0]*60+n[1])*60+n[2])*1000+n[3]
        end = ((n[4]*60+n[5])*60+n[6])*1000+n[7]
        words = '\n'.join(lines[2:]).strip()
        if not 0 <= start < end <= 3600000 or not 0 < len(words) <= 4000 or len(cues) >= 50000 or '\0' in words:
            raise ValueError('broadcast_caption_limit')
        cues.append({'cueId': hashlib.sha256(f'{job["fingerprint"]}:{len(cues)}:{start}:{end}:{words}'.encode()).hexdigest(),
                     'startMs': start, 'endMs': end, 'text': words})
    if not cues: raise ValueError('no_selected_broadcast_captions')
    try:
        version = _capture([executable, '--version'], 4096, 5).decode('utf-8', errors='replace').splitlines()[0][:160]
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        version = 'version-unreported'
    return {'cues': cues, 'wordTimings': [], 'language': job.get('language') or 'unknown',
        'durationMs': max(c['endMs'] for c in cues), 'model': {'decoder': 'CCExtractor', 'version': version},
        'broadcastEvidence': {'kind': kind, 'service': service, 'program': program, 'decoder': version,
            'outputSha256': hashlib.sha256(raw).hexdigest(), 'clock': 'decoder-relative-uploaded-file',
            'maximumProcessedSeconds': 3600, 'nativeServiceLayoutPreserved': False, 'qualityQualified': False},
        'warnings': ['Only the explicitly selected CEA caption service is extracted, up to the first hour. '
            'For transport streams with multiple programs, select a program; no arbitrary first program is chosen.',
            'SRT flattens caption windows, roll-up/pop-on/paint-on presentation, colors and native positioning. '
            'Decoder timestamps, broadcaster discontinuities and character decoding require review. '
            'This is a separate text derivative; native caption playback and original media remain unchanged.']}
