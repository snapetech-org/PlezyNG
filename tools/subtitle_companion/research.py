"""Opt-in evidence-producing adapters; model agreement is not ground truth.

Only host-selected local model directories are accepted. No client-provided
module paths, Python, shell commands, or remote model code are executed.
"""
from __future__ import annotations
import difflib
import hashlib
import math
import os
from pathlib import Path
import re
import subprocess
import wave

AUDIO_TASKS = {'ensemble', 'separate', 'sound_events', 'completeness'}
MEDIA_TASKS = AUDIO_TASKS | {'extract_text', 'signs', 'dub_mix', 'ocr_auto', 'scene_review'}


def model_directory(variable):
    value = os.environ.get(variable, '')
    path = Path(value)
    if not value or not path.is_absolute() or not path.is_dir():
        raise ValueError('configure_local_research_model')
    return path


def merged(intervals):
    output = []
    for start, end in sorted(intervals):
        if output and start <= output[-1][1]: output[-1][1] = max(output[-1][1], end)
        else: output.append([start, end])
    return output


def completeness(folder, job, audio, device, progress, recognize):
    from faster_whisper.vad import get_speech_timestamps, VadOptions
    speech = get_speech_timestamps(audio, vad_options=VadOptions(min_speech_duration_ms=300,
        min_silence_duration_ms=300, speech_pad_ms=0), sampling_rate=16000)
    coverage = merged((c['startMs'], c['endMs']) for c in job['cues'])
    gaps, speech_ms, uncovered, cursor = [], 0, 0, 0
    for event in speech:
        a, b = event['start'] // 16, event['end'] // 16
        speech_ms += b - a
        while cursor < len(coverage) and coverage[cursor][1] <= a: cursor += 1
        start, i = a, cursor
        while i < len(coverage) and coverage[i][0] < b:
            left, right = coverage[i]
            if left > start: gaps.append([start, min(left, b)])
            start = max(start, right)
            i += 1
        if start < b: gaps.append([start, b])
    gaps = merged(gaps)
    uncovered = sum(b - a for a, b in gaps)
    warnings = ['Speech coverage is a VAD heuristic, not proof of missing dialogue. Forced/sign-only tracks intentionally leave speech uncovered.',
        f'{uncovered} of {speech_ms} detected speech milliseconds are outside cue intervals; source cues were not changed.']
    warnings += [f'Possible uncovered speech: {a}–{b} ms' for a, b in gaps if b - a >= 500][:90]
    return {'cues': job['cues'], 'sourceCues': job['cues'], 'wordTimings': [], 'durationMs': round(len(audio) / 16),
            'language': job.get('language') or 'unknown', 'model': 'faster-whisper bundled Silero VAD',
            'coverageEvidence': {'speechMs': speech_ms, 'uncoveredMs': uncovered, 'gaps': gaps[:10000]}, 'warnings': warnings}


def ensemble(folder, job, audio, device, progress, recognize):
    second_model = str(model_directory('PLEZY_SECOND_WHISPER_MODEL'))
    baseline = recognize(folder, job, audio, device)
    second = recognize(folder, job, audio, device, model_name=second_model)
    candidates, cursor, comparisons = [], 0, 0
    for cue in baseline['cues']:
        while cursor < len(second['cues']) and second['cues'][cursor]['endMs'] < cue['startMs'] - 500: cursor += 1
        matching = []
        for other in second['cues'][cursor:cursor + 32]:
            if other['startMs'] > cue['endMs'] + 500: break
            if min(cue['endMs'], other['endMs']) > max(cue['startMs'], other['startMs']): matching.append(other)
        text = ' '.join(c['text'] for c in matching).strip()
        if not text or len(text) > 4000: continue
        comparisons += 1
        agreement = difflib.SequenceMatcher(None, cue['text'].casefold(), text.casefold(), autojunk=True).ratio()
        if agreement < .9:
            candidates.append({'cueId': cue['cueId'], 'text': text, 'agreement': agreement,
                               'reason': 'independent ASR disagreement; timing retained from first pass'})
    baseline.update({'alternatives': candidates[:5000], 'ensembleEvidence': {'compared': comparisons,
        'disagreements': len(candidates), 'secondModel': Path(second_model).name},
        'warnings': ['Two independent recognition passes were compared. Baseline text is retained; disagreement alternatives require explicit review.',
                     f'{len(candidates)} disagreements across {comparisons} overlapping cue comparisons. Agreement is not an accuracy score.']})
    return baseline


def separate(folder, job, audio, device, progress, recognize):
    import numpy as np
    import torch
    import torchaudio
    from speechbrain.inference.separation import SepformerSeparation
    if len(audio) > 300 * 16000: raise ValueError('separation_limit_five_minutes')
    path = model_directory('PLEZY_SEPARATOR_MODEL')
    separator = SepformerSeparation.from_hparams(source=str(path), savedir=str(path), run_opts={'device': device})
    rate = int(separator.hparams.sample_rate)
    if rate not in {8000, 16000} or int(separator.hparams.num_spks) not in {2, 3}:
        raise ValueError('unsupported_separation_model_shape')
    output, words = [], []
    for number, start in enumerate(range(0, len(audio), 8 * 16000)):
        left = max(0, start - 16000)
        chunk = torch.from_numpy(audio[left:min(len(audio), start + 9 * 16000)]).unsqueeze(0)
        chunk = torchaudio.functional.resample(chunk, 16000, rate)
        with torch.inference_mode(): stems = separator.separate_batch(chunk.to(device)).detach().cpu()
        if stems.ndim != 3 or stems.shape[2] not in {2, 3}: raise ValueError('invalid_separator_output')
        for speaker in range(stems.shape[2]):
            values = torchaudio.functional.resample(stems[0, :, speaker], rate, 16000).numpy().astype(np.float32)
            if not np.isfinite(values).all(): raise ValueError('invalid_separator_samples')
            values = np.clip(values, -1, 1)
            result = recognize(folder, job, values, device)
            for cue in result['cues']:
                a, b = cue['startMs'] + left // 16, cue['endMs'] + left // 16
                if not start // 16 <= (a + b) // 2 < (start + 8 * 16000) // 16: continue
                # Permutation can change between windows. Never imply a stable identity.
                text = f'VOICE CANDIDATE {speaker + 1}, WINDOW {number + 1}: {cue["text"]}'
                identifier = hashlib.sha256(f'{job["audioDigest"]}:{number}:{speaker}:{a}:{b}:{text}'.encode()).hexdigest()
                output.append({**cue, 'cueId': identifier, 'startMs': a, 'endMs': b, 'text': text,
                               'speakerWindow': number, 'speakerCandidate': speaker})
        progress(folder, 'Separating and recognizing overlapping voice candidates', start / len(audio))
    output.sort(key=lambda c: (c['startMs'], c['endMs']))
    return {'cues': output, 'wordTimings': words, 'language': job.get('language') or 'unknown',
            'durationMs': round(len(audio) / 16), 'model': 'SpeechBrain ' + path.name,
            'warnings': ['Experimental separation can create artifacts or leak one speaker into another. Parallel cues are candidates, not verified voices.',
                'Speaker numbering restarts in every 8-second window. Voice identity and separation quality have not been evaluated.']}


def sound_events(folder, job, audio, device, progress, recognize):
    from transformers import pipeline
    path = model_directory('PLEZY_SOUND_MODEL')
    classifier = pipeline('audio-classification', model=str(path), device=0 if device == 'cuda' else -1,
                          trust_remote_code=False)
    events, active = [], None
    for start in range(0, len(audio), 40000):
        chunk = audio[start:start + 80000]
        if len(chunk) < 8000: break
        rows = classifier({'array': chunk, 'sampling_rate': 16000}, top_k=2)
        top = rows[0] if rows else {}
        score = float(top.get('score', 0))
        label = str(top.get('label', ''))
        if not math.isfinite(score) or not re.fullmatch(r'[\w ,()\-/]{1,100}', label): label = ''
        if score < .8: label = ''
        a, b = start // 16, (start + len(chunk)) // 16
        if label and active is not None and active['label'] == label:
            active['endMs'] = b; active['observations'] += 1; active['score'] = min(active['score'], score)
        else:
            if active and active['observations'] >= 2: events.append(active)
            active = {'label': label, 'startMs': a, 'endMs': b, 'observations': 1, 'score': score} if label else None
        progress(folder, 'Classifying repeated sound-event candidates', start / len(audio))
    if active and active['observations'] >= 2: events.append(active)
    cues = []
    for event in events:
        text = '[Possible sound: ' + event['label'] + ']'
        cue = {**event, 'text': text, 'cueId': hashlib.sha256(f'{job["audioDigest"]}:{event}'.encode()).hexdigest()}
        cues.append(cue)
    return {'cues': cues, 'wordTimings': [], 'language': 'en', 'durationMs': round(len(audio) / 16),
        'model': 'audio-classification ' + path.name, 'warnings': [
            'Experimental sound-event candidates require two overlapping windows at score ≥0.8. Scores are not calibrated accuracy.',
            'These are separate from spoken dialogue. Mono analysis cannot determine spatial direction or verify a sound source.']}


def extract_text(folder, job, progress):
    """mov_text/ASS/etc through FFmpeg's explicit text conversion, never OCR."""
    output = folder / 'extracted.srt'
    result = subprocess.run([os.environ.get('PLEZY_FFMPEG', 'ffmpeg'), '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
        '-protocol_whitelist', 'file,pipe', '-format_whitelist', 'matroska,webm,mov,avi,mpegts,mpeg',
        '-i', str(folder / 'input.media'), '-map', f'0:s:{job["subtitleTrack"]}', '-t', '3600', '-fs', str(5 * 1024**2),
        '-c:s', 'srt', str(output)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1800)
    if result.returncode or output.stat().st_size >= 5 * 1024**2: raise ValueError('subtitle_extraction_failed_or_limit')
    text = output.read_text(encoding='utf-8-sig')
    pattern = re.compile(r'(?m)^\d+\s*\n(\d{2,}):(\d{2}):(\d{2}),(\d{3}) --> (\d{2,}):(\d{2}):(\d{2}),(\d{3})[^\n]*\n(.*?)(?=\n\s*\n|\Z)', re.S)
    cues = []
    for match in pattern.finditer(text):
        n = [int(v) for v in match.groups()[:8]]
        a = ((n[0] * 60 + n[1]) * 60 + n[2]) * 1000 + n[3]
        b = ((n[4] * 60 + n[5]) * 60 + n[6]) * 1000 + n[7]
        value = match[9].strip()
        if not 0 <= a < b <= 3600000 or not 0 < len(value) <= 4000 or len(cues) >= 50000: raise ValueError('invalid_extracted_subtitle')
        cues.append({'cueId': hashlib.sha256(f'{job["audioDigest"]}:{len(cues)}:{a}:{b}:{value}'.encode()).hexdigest(),
                     'startMs': a, 'endMs': b, 'text': value})
    return {'cues': cues, 'wordTimings': [], 'language': job.get('language') or 'unknown',
        'durationMs': max((c['endMs'] for c in cues), default=0), 'model': 'FFmpeg subtitle decoder',
        'warnings': ['Text-stream extraction creates a separate SRT. Native layout, animation and closed-caption service behavior are flattened; originals remain unchanged.']}
