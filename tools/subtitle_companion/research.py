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
MEDIA_TASKS = AUDIO_TASKS | {'extract_text', 'signs', 'dub_mix', 'ocr_auto', 'scene_review', 'scene_track', 'singing_align', 'sound_localize'}


def harmonic_view(audio):
    """Bounded median-mask harmonic/percussive view, NOT a vocal isolator.

    Uses original-rate samples and overlap/add, never stretches lyrics or
    assigns evenly spaced word times. Harmonic instruments survive this mask.
    """
    import numpy as np
    frame, hop, context = 1024, 256, 2048
    window = np.hanning(frame).astype(np.float32)
    output = np.empty_like(audio)
    for start in range(0, len(audio), 16 * 16000):
        end = min(len(audio), start + 16 * 16000)
        left, right = max(0, start-context), min(len(audio), end+context)
        samples = audio[left:right]
        padded = np.pad(samples, (frame//2, frame), mode='reflect')
        frames = np.lib.stride_tricks.sliding_window_view(padded, frame)[::hop]
        spectrum = np.fft.rfft(frames * window)
        magnitude = np.abs(spectrum).astype(np.float32)
        # A 17-frame/time and 17-bin/frequency median. Windows are views;
        # temporaries are bounded by this 16-second chunk, not the whole song.
        horizontal = np.median(np.lib.stride_tricks.sliding_window_view(
            np.pad(magnitude, ((8, 8), (0, 0)), mode='edge'), 17, axis=0), axis=-1)
        vertical = np.median(np.lib.stride_tricks.sliding_window_view(
            np.pad(magnitude, ((0, 0), (8, 8)), mode='edge'), 17, axis=1), axis=-1)
        mask = horizontal**2 / np.maximum(horizontal**2 + vertical**2, 1e-12)
        inverse = np.fft.irfft(spectrum * mask, n=frame).astype(np.float32)
        signal = np.zeros((len(frames)-1)*hop + frame, dtype=np.float32)
        weight = np.zeros_like(signal)
        for i, values in enumerate(inverse):
            at = i*hop
            signal[at:at+frame] += values * window
            weight[at:at+frame] += window * window
        signal /= np.maximum(weight, 1e-8)
        reconstructed = signal[frame//2:frame//2+len(samples)]
        output[start:end] = reconstructed[start-left:end-left]
    if not np.isfinite(output).all(): raise ValueError('invalid_harmonic_analysis_samples')
    return np.clip(output, -1, 1)


def singing_align(folder, job, audio, device, progress, align, load_runtime):
    """Conservative lyric word proposals from two acoustic views of one mix."""
    if len(audio) > 300 * 16000 or len(job['cues']) > 120 or any(
            cue['endMs']-cue['startMs'] > 30000 for cue in job['cues']):
        raise ValueError('lyric_alignment_limit_five_minutes_120_cues_30_seconds_per_cue')
    path = model_directory('PLEZY_SINGING_ALIGN_MODEL')
    import json
    config = json.loads((path / 'config.json').read_text(encoding='utf-8'))
    if (config.get('model_type') != 'wav2vec2' or 'Wav2Vec2ForCTC' not in config.get('architectures', []) or
            config.get('auto_map') or not (path / 'vocab.json').is_file()):
        raise ValueError('configure_supported_local_lyric_ctc_model')
    runtime = load_runtime(job['language'], device, explicit_model=str(path))
    characters = bool(job.get('lyricSyllables'))
    baseline = align(folder, job, audio, device, runtime=runtime, capture_characters=characters)
    progress(folder, 'Comparing original and percussive-suppressed lyric evidence', .45)
    harmonic_audio = harmonic_view(audio)
    alternate = align(folder, job, harmonic_audio, device, runtime=runtime, capture_characters=characters)
    def grouped(result):
        groups = {}
        for word in result['wordTimings']: groups.setdefault(word['cueId'], []).append(word)
        return groups
    original, harmonic = grouped(baseline), grouped(alternate)
    words, evidence, uncertain = [], [], []
    def spelling(value): return re.sub(r'\W', '', value.casefold())
    for cue in job['cues']:
        a, b = original.get(cue['cueId'], []), harmonic.get(cue['cueId'], [])
        differences = []
        agrees = bool(a) and len(a) == len(b)
        if agrees:
            for one, two in zip(a, b):
                drift = max(abs(one['startMs']-two['startMs']), abs(one['endMs']-two['endMs']))
                differences.append(drift)
                if not spelling(one['text']) or spelling(one['text']) != spelling(two['text']) or drift > 250:
                    agrees = False
        if agrees: words.extend(a)
        else: uncertain.append(cue['cueId'])
        evidence.append({'cueId': cue['cueId'], 'acceptedWords': len(a) if agrees else 0,
            'originalWords': len(a), 'harmonicWords': len(b), 'maximumBoundaryDifferenceMs': max(differences) if differences else None,
            'status': 'two-view-agreement-unqualified' if agrees else 'retain-original-no-word-proposal'})
    from lyric_research import syllable_proposals, pitch_evidence
    syllables, syllable_evidence = syllable_proposals(job, baseline, alternate)
    syllable_ids = {unit['cueId'] for unit in syllables}
    words = [word for word in words if word['cueId'] not in syllable_ids] + syllables
    words.sort(key=lambda word: (word['startMs'], word['endMs']))
    uncertain = [key for key in uncertain if key not in syllable_ids]
    pitch = pitch_evidence(job, audio, harmonic_audio) if job.get('lyricPitchEvidence') else []
    return {'cues': job['cues'], 'sourceCues': job['cues'], 'wordTimings': words,
        'lyricSyllableEvidence': syllable_evidence, 'lyricPitchEvidence': pitch,
        'language': job['language'], 'durationMs': round(len(audio)/16), 'model': 'lyric CTC / ' + path.name,
        'uncertainCueIds': uncertain, 'lyricTimingEvidence': evidence,
        'warnings': ['Lyric text and cue bounds remain unchanged. Only CTC word proposals agreeing within 250 ms across original and harmonic views are retained.',
            'The spectral mask suppresses percussion; it does not isolate vocals. Harmonic instruments, vibrato, melisma and overlapping singers can defeat both views.',
            'CTC confidence and two-view agreement are uncalibrated. Syllable units are supplied by the viewer and require valid character alignment in both views; no evenly spaced timing is substituted.',
            'Optional pitch candidates measure the uploaded mix. Instruments, harmonies and octave errors can dominate them; they are not verified vocal notes and do not change lyric timing.',
            f'{len(uncertain)} cues have no accepted word proposal. Review against the song before enabling karaoke.']}


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


def stereo_evidence(folder, job, events):
    """Measure the stereo rendering of the selected audio, never physical origin.

    A classifier observes a mixed signal; energy balance is not event separation
    or a localization estimate. Delay/correlation also describe the encoded mix,
    not a physical source direction. Keep both event and window work bounded.
    """
    from worker import FORMATS
    import numpy as np
    maximum_events, maximum_windows, maximum_windows_per_event = 128, 1024, 8
    total_windows = 0
    target = folder / 'sound_stereo.wav'
    command = [os.environ.get('PLEZY_FFMPEG', 'ffmpeg'), '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
        '-protocol_whitelist', 'file,pipe', '-format_whitelist', FORMATS,
        '-i', str(folder / 'input.media'), '-map', f'0:a:{job["audioTrack"]}', '-vn', '-sn',
        '-ac', '2', '-ar', '16000', '-t', '3600.1', '-c:a', 'pcm_s16le', '-f', 'wav', str(target)]
    try:
        result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=1800)
        if result.returncode: raise ValueError('stereo_evidence_decode_failed')
        with wave.open(str(target), 'rb') as stream:
            if stream.getnchannels() != 2 or stream.getsampwidth() != 2 or stream.getframerate() != 16000 or stream.getnframes() > 3600 * 16000:
                raise ValueError('stereo_evidence_duration_or_layout')
            for event_number, event in enumerate(events):
                if event_number >= maximum_events:
                    event['stereoEvidence'] = {'status': 'event-budget-limit', 'eventLocalized': False,
                        'physicalDirectionDegrees': None, 'qualification': 'unverified'}
                    continue
                balances, lags, correlations = [], [], []
                event_windows = 0
                window_limit = min(maximum_windows_per_event, maximum_windows - total_windows)
                for ms in range(event['startMs'], event['endMs'], 500):
                    if event_windows >= window_limit: break
                    frame = ms * 16
                    if frame >= stream.getnframes(): break
                    stream.setpos(frame)
                    data = np.frombuffer(stream.readframes(min(8000, (event['endMs'] - ms) * 16)), dtype='<i2').reshape(-1, 2).astype(np.float64) / 32768
                    if len(data) < 1600: continue
                    event_windows += 1
                    total_windows += 1
                    power = np.mean(data * data, axis=0)
                    if max(power) < 1e-6: continue
                    balances.append(10 * math.log10((float(power[0]) + 1e-12) / (float(power[1]) + 1e-12)))
                    # A centered 128 ms sample bounds the local delay estimate.
                    # Positive lag means the left channel trails the right.
                    sample_start = max(0, (len(data) - 2048) // 2)
                    sample = data[sample_start:sample_start + 2048]
                    if len(sample) >= 1024:
                        left, right = sample[:, 0] - np.mean(sample[:, 0]), sample[:, 1] - np.mean(sample[:, 1])
                        best_lag, best_correlation = 0, 0.0
                        for lag in range(-16, 17):
                            if lag > 0: a, b = left[lag:], right[:-lag]
                            elif lag < 0: a, b = left[:lag], right[-lag:]
                            else: a, b = left, right
                            denominator = math.sqrt(float(np.dot(a, a)) * float(np.dot(b, b)))
                            if denominator < 1e-8: continue
                            value = float(np.dot(a, b)) / denominator
                            if abs(value) > abs(best_correlation) or abs(value) == abs(best_correlation) and abs(lag) < abs(best_lag):
                                best_lag, best_correlation = lag, value
                        if abs(best_correlation) >= .5:
                            lags.append(best_lag)
                            correlations.append(abs(best_correlation))
                left = sum(value >= 6 for value in balances) / len(balances) if balances else 0
                right = sum(value <= -6 for value in balances) / len(balances) if balances else 0
                side = 'left' if len(balances) >= 4 and left >= .8 else 'right' if len(balances) >= 4 and right >= .8 else 'indeterminate'
                event['stereoEvidence'] = {'rendering': 'ffmpeg-stereo-downmix', 'halfSecondWindows': len(balances),
                    'medianLeftMinusRightDb': round(float(np.median(balances)), 2) if balances else None, 'mixSide': side,
                    'interchannelLagSampleRateHz': 16000,
                    'medianInterchannelLagSamples': round(float(np.median(lags)), 2) if len(lags) >= 4 else None,
                    'medianAbsoluteInterchannelCorrelation': round(float(np.median(correlations)), 3) if len(correlations) >= 4 else None,
                    'correlationWindows': len(lags), 'positiveLagMeansLeftTrailsRight': True,
                    'physicalDirectionDegrees': None, 'eventLocalized': False, 'qualification': 'unverified',
                    'windowBudgetReached': total_windows >= maximum_windows}
    finally: target.unlink(missing_ok=True)


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
    if job.get('soundStereoEvidence'): stereo_evidence(folder, job, events)
    cues = []
    for event in events:
        side = event.get('stereoEvidence', {}).get('mixSide', 'indeterminate')
        text = '[Possible sound: ' + event['label'] + (f'; audio mix weighted {side}' if side != 'indeterminate' else '') + ']'
        cue = {**event, 'text': text, 'cueId': hashlib.sha256(f'{job["audioDigest"]}:{event}'.encode()).hexdigest()}
        cues.append(cue)
    return {'cues': cues, 'wordTimings': [], 'language': 'en', 'durationMs': round(len(audio) / 16),
        'model': 'audio-classification ' + path.name, 'soundEvidence': events, 'warnings': [
            'Experimental sound-event candidates require two overlapping windows at score ≥0.8. Scores are not calibrated accuracy.',
            'These are separate from dialogue. Optional stereo evidence describes the complete downmixed audio, not an isolated event or physical direction. Mix-side weighting requires 6 dB dominance in 80% of at least four windows; delay/correlation uses centered 128 ms samples and requires four correlated windows. Both are bounded heuristics, not localization accuracy.']}


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
