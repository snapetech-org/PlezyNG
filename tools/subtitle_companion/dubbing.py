"""Explicit subtitle-driven speech stem/mix; local licensed Piper voice only.

No voice cloning, inferred identity, lip-sync claim or silent timing truncation.
Inputs are already-reviewed target-language cues on the supplied media clock.
"""
from __future__ import annotations
from functools import lru_cache
import json
import hashlib
import os
from pathlib import Path
import re
import subprocess
import wave

RATE = 16000
MAX_MS = 600000
MAX_ARTIFACT = 32 * 1024**2


def voice_config():
    path = Path(os.environ.get('PLEZY_PIPER_MODEL', ''))
    license_text = os.environ.get('PLEZY_PIPER_LICENSE', '').strip()
    if not path.is_absolute() or not path.is_file() or path.suffix != '.onnx' or not 0 < path.stat().st_size <= 512 * 1024**2 or not 1 <= len(license_text) <= 1000:
        raise ValueError('configure_local_piper_model_and_voice_license')
    return path, license_text


@lru_cache(maxsize=8)
def _voice_digest(path, size, modified):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024**2), b''): digest.update(block)
    return digest.hexdigest()


def capabilities():
    path, license_text = voice_config()
    stat = path.stat()
    info = {'voice': path.stem, 'sha256': _voice_digest(str(path), stat.st_size, stat.st_mtime_ns),
            'license': license_text, 'device': 'cpu', 'maximumDurationMs': MAX_MS, 'maximumCues': 500}
    info['fingerprint'] = hashlib.sha256(json.dumps(info, sort_keys=True).encode()).hexdigest()
    return info


def run(folder, job, progress, original=None):
    import numpy as np
    from piper import PiperVoice
    model, license_text = voice_config()
    voice_info = capabilities()
    if job.get('voiceFingerprint') != voice_info['fingerprint']: raise ValueError('voice_changed_resubmit_after_review')
    cues = job['cues']
    end_ms = max(c['endMs'] for c in cues)
    if len(cues) > 500 or end_ms > MAX_MS or any(c['endMs'] - c['startMs'] > 60000 for c in cues):
        raise ValueError('dubbing_limit_ten_minutes_five_hundred_cues')
    if original is not None and len(original) > RATE * 600:
        raise ValueError('dubbing_mix_media_limit_ten_minutes')
    duration = max(round(end_ms * RATE / 1000), len(original) if original is not None else 0)
    speech = np.zeros(duration, dtype=np.float32)
    mask = np.ones(duration, dtype=np.float32)
    voice = PiperVoice.load(str(model), use_cuda=False)
    warnings, evidence, emitted = [], [], 0
    source = folder / 'utterance.wav'
    fitted = folder / 'fitted.wav'
    try:
        for i, cue in enumerate(cues):
            text = re.sub(r'<[^>]*>|\{[^}]*\}', '', cue['text']).replace('\\N', '\n').strip()
            if not text: continue
            count, native_rate = 0, None
            with wave.open(str(source), 'wb') as output:
                for chunk in voice.synthesize(text):
                    if chunk.sample_width != 2 or chunk.sample_channels != 1 or not 8000 <= chunk.sample_rate <= 48000:
                        raise ValueError('unsupported_voice_audio_format')
                    if native_rate is None:
                        native_rate = chunk.sample_rate
                        output.setparams((1, 2, native_rate, 0, 'NONE', 'not compressed'))
                    if native_rate != chunk.sample_rate: raise ValueError('voice_sample_rate_changed')
                    data = chunk.audio_int16_bytes
                    count += len(data) // 2
                    if count > native_rate * 60: raise ValueError('synthesized_utterance_duration_limit')
                    output.writeframesraw(data)
            if not count or native_rate is None: raise ValueError('voice_returned_no_audio')
            available = (cue['endMs'] - cue['startMs']) / 1000
            speed = max(1.0, count / native_rate / max(.05, available - .02))
            if speed > 2:
                warnings.append(f"Cue {i + 1}: synthesis omitted because fitting would require more than 2× speed. Shorten the wording or extend the cue; no speech was cut silently.")
                evidence.append({'cueId': cue['cueId'], 'status': 'omitted_too_long'})
                continue
            command = [os.environ.get('PLEZY_FFMPEG', 'ffmpeg'), '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
                '-protocol_whitelist', 'file,pipe', '-i', str(source), '-af', f'atempo={speed:.8f},apad',
                '-t', str(available), '-ar', str(RATE), '-ac', '1', '-c:a', 'pcm_s16le', '-fs', str(2 * RATE * 61), str(fitted)]
            if subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=90).returncode:
                raise ValueError('dubbing_time_fit_failed')
            with wave.open(str(fitted), 'rb') as stream:
                if stream.getnframes() > RATE * 61 or stream.getsampwidth() != 2 or stream.getnchannels() != 1 or stream.getframerate() != RATE:
                    raise ValueError('invalid_fitted_voice_audio')
                samples = np.frombuffer(stream.readframes(stream.getnframes()), dtype='<i2').astype(np.float32) / 32768
            start = round(cue['startMs'] * RATE / 1000)
            stop = min(duration, round(cue['endMs'] * RATE / 1000), start + len(samples))
            samples = samples[:stop-start]
            fade = min(80, len(samples) // 2)
            if fade:
                samples[:fade] *= np.linspace(0, 1, fade)
                samples[-fade:] *= np.linspace(1, 0, fade)
            speech[start:stop] += samples * .85
            if original is not None:
                level = float(job.get('duckRatio', .25))
                envelope = np.full(stop-start, level, dtype=np.float32)
                ramp = min(320, len(envelope) // 2)
                if ramp:
                    envelope[:ramp] = np.linspace(1, level, ramp)
                    envelope[-ramp:] = np.linspace(level, 1, ramp)
                mask[start:stop] = np.minimum(mask[start:stop], envelope)
            evidence.append({'cueId': cue['cueId'], 'status': 'synthesized', 'speed': speed})
            emitted += 1
            progress(folder, 'Synthesizing and fitting a separate audio product', (i + 1) / len(cues))
        if not emitted: raise ValueError('no_dubbing_cues_fit_their_intervals')
        if original is not None: speech[:len(original)] += original * mask[:len(original)]
        peak = float(np.max(np.abs(speech)))
        gain = min(1.0, .98 / max(.001, peak))
        data = (np.clip(speech * gain, -1, 1) * 32767).astype('<i2')
        target = folder / 'dubbed.wav'
        with wave.open(str(target), 'wb') as output:
            output.setparams((1, 2, RATE, len(data), 'NONE', 'not compressed'))
            output.writeframes(data.tobytes())
        if target.stat().st_size > MAX_ARTIFACT: raise ValueError('dubbing_artifact_limit')
        digest = hashlib.sha256()
        with model.open('rb') as stream:
            for block in iter(lambda: stream.read(1024**2), b''): digest.update(block)
        return {'cues': cues, 'wordTimings': [], 'language': job['language'], 'durationMs': round(duration / RATE * 1000),
            'artifacts': [{'name': 'dubbed.wav', 'mime': 'audio/wav', 'bytes': target.stat().st_size,
                'sha256': hashlib.sha256(target.read_bytes()).hexdigest()}],
            'synthesisEvidence': evidence, 'normalizationGain': gain,
            'model': {'family': 'Piper', 'voice': model.stem, 'sha256': digest.hexdigest(), 'license': license_text},
            'warnings': ['Separate synthetic voice audio, not the original speaker and not lip-synchronized. Review pronunciation, meaning, fitted speed and omitted cues.',
                'Mono 16 kHz PCM output. Original audio is ducked only in the explicit mix task; source files are unchanged.'] + warnings[:98]}
    finally:
        source.unlink(missing_ok=True); fitted.unlink(missing_ok=True)
