"""Solo-vocal note proposals with explicit source declaration and human review.

pYIN and YIN share a family of assumptions; agreement is not independent proof.
"""
import hashlib
import math
import wave
from collections import Counter

MAX_INPUT_BYTES = 4 * 1024**2


def validate(job):
    cues = job.get('cues', [])
    if job.get('isolatedLeadVocal') is not True:
        raise ValueError('declare_time_preserving_isolated_lead_vocal')
    if (not 1 <= len(cues) <= 120 or any(c['endMs'] > 120000 or c['endMs']-c['startMs'] > 12000 for c in cues) or
            sum(c['endMs']-c['startMs'] for c in cues) > 120000):
        raise ValueError('vocal_notes_limit_twelve_seconds_per_cue_two_minutes_total')
    if job.get('preprocess') or job.get('audioTrack', 0) or job.get('itemTimeline') or job.get('timelineOffsetMs', 0):
        raise ValueError('vocal_notes_require_original_file_clock_and_no_preprocessing')


def run(folder, job, progress):
    import librosa
    import numpy as np
    validate(job)
    frame, hop, rate = 2048, 320, 16000
    names = ('C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B')
    rows, retained = [], 0
    if (folder/'input.media').stat().st_size > MAX_INPUT_BYTES: raise ValueError('vocal_note_input_limit')
    with wave.open(str(folder/'input.media'), 'rb') as source:
        if (source.getcomptype() != 'NONE' or source.getnchannels() != 1 or source.getsampwidth() != 2 or
                source.getframerate() != rate or not 0 < source.getnframes() <= rate*120):
            raise ValueError('vocal_notes_require_mono_pcm_sixteen_bit_sixteen_khz_wav')
        duration = source.getnframes()//16
        if max(c['endMs'] for c in job['cues']) > duration: raise ValueError('vocal_note_cue_exceeds_source')
        for cue_index, cue in enumerate(job['cues']):
            progress(folder, 'Proposing notes from declared solo vocal; review required', cue_index/len(job['cues']))
            source.setpos(cue['startMs']*16)
            count = (cue['endMs']-cue['startMs'])*16
            raw = source.readframes(count)
            if len(raw) != count*2: raise ValueError('vocal_source_truncated')
            audio = np.frombuffer(raw, dtype='<i2').astype(np.float32)/32768
            notes, group, rejected = [], [], Counter()
            analyzed, agreed, omitted = 0, 0, 0
            def flush():
                nonlocal retained, omitted
                if len(group) < 5:
                    if group: rejected['short_stable_group'] += len(group)
                    group.clear(); return
                if len(notes) >= 80 or retained >= 1000:
                    omitted += 1; group.clear(); return
                start, end, midi = group[0][0]-10, group[-1][0]+10, group[0][1]
                median = float(np.median([value[2] for value in group]))
                note_id = hashlib.sha256(f"{job['audioDigest']}:{cue['cueId']}:{start}:{end}:{midi}".encode()).hexdigest()
                notes.append({'noteId': note_id, 'startMs': start, 'endMs': end, 'midi': midi,
                    'note': names[midi % 12]+str(midi//12-1), 'medianHz': round(median, 3),
                    'medianCentsFromNote': round(1200*math.log2(median/(440*2**((midi-69)/12))), 2),
                    'minimumVoicedScore': round(min(value[3] for value in group), 4)})
                retained += 1; group.clear()
            if len(audio) >= frame and float(np.sqrt(np.mean(audio*audio))) >= 1e-4:
                f0, voiced, score = librosa.pyin(audio, sr=rate, fmin=65, fmax=1000,
                    frame_length=frame, hop_length=hop, center=False, n_thresholds=32, fill_na=np.nan)
                alternate = librosa.yin(audio, sr=rate, fmin=65, fmax=1000,
                    frame_length=frame, hop_length=hop, center=False)
                for i, (hz, present, probability, other) in enumerate(zip(f0, voiced, score, alternate)):
                    analyzed += 1
                    reason = None
                    samples = audio[i*hop:i*hop+frame]
                    if float((np.abs(samples) >= .995).mean()) > .005: reason = 'clipping'
                    elif not present or not np.isfinite([hz, probability, other]).all() or min(hz, other) <= 0 or probability < .8:
                        reason = 'unvoiced_or_low_score'
                    elif abs(1200*math.log2(hz/other)) > 35: reason = 'estimator_disagreement'
                    if reason:
                        rejected[reason] += 1; flush(); continue
                    pitch = 69+12*math.log2(hz/440)
                    midi = round(pitch)
                    if abs(pitch-midi) > .35:
                        rejected['unstable_or_between_notes'] += 1; flush(); continue
                    at = cue['startMs']+(i*hop+frame//2)//16
                    if at-10 < cue['startMs'] or at+10 > cue['endMs']:
                        rejected['outside_cue'] += 1; flush(); continue
                    agreed += 1
                    if group and (group[-1][1] != midi or at-group[-1][0] > 20): flush()
                    group.append((at, midi, float(hz), float(probability)))
                flush()
            rows.append({'cueId': cue['cueId'], 'candidates': notes, 'analyzedFrames': analyzed,
                'agreedFrames': agreed, 'rejectedFrames': dict(rejected), 'omittedCandidateGroups': omitted,
                'unprocessedReason': 'too_short_or_low_energy' if analyzed == 0 else None})
    return {'cues': job['cues'], 'sourceCues': job['cues'], 'wordTimings': [], 'durationMs': duration,
        'language': job.get('language') or 'unknown', 'model': 'librosa-pyin-yin-solo-vocal-candidates',
        'vocalNoteEvidence': {'declaredIsolatedLeadVocal': True, 'isolationVerified': False,
            'algorithm': 'pYIN with YIN consistency check', 'version': librosa.__version__,
            'sampleRate': rate, 'frameSamples': frame, 'hopSamples': hop, 'analysisWindowMs': 128,
            'outputGridMs': 20, 'boundaryErrorBoundMs': None, 'minimumVoicedScore': .8,
            'maximumEstimatorDifferenceCents': 35, 'minimumStableGroupMs': 100, 'cues': rows},
        'warnings': ['The input is declared to be an isolated lead vocal on its original file clock; the host has not verified isolation or alignment with the main recording.',
            'Pitch proposals are separate from lyric/word timing. Instrument bleed, harmonies, octave errors, vibrato, slides and melisma can defeat both related estimators.',
            'Frame centers are 20 ms apart but each analysis window spans 128 ms. Neither the output grid nor estimator agreement establishes onset/offset accuracy.',
            'Review, correct and explicitly select individual notes against the source before exporting a viewer-reviewed note track. No note is automatically accepted and caption text/timing remain unchanged.']}
