"""Explicit lyric segmentation and bounded, unqualified pitch evidence."""
import math
import re


def plain_lyrics(text):
    text = re.sub(r'<(?:rt|rp)\s*>[\s\S]*?</(?:rt|rp)\s*>', '', text, flags=re.I)
    return re.sub(r'<[^>]{0,160}>|\{[^}]{0,160}\}', '', text).replace('\\N', ' ').strip()


def validate_syllables(value, cues):
    if not isinstance(value, dict) or len(value) > 120:
        raise ValueError('invalid_lyric_syllable_map')
    sources = {cue['cueId']: plain_lyrics(cue['text']) for cue in cues}
    count = 0
    for key, units in value.items():
        if key not in sources or not isinstance(units, list) or not 2 <= len(units) <= 128 or any(
                not isinstance(unit, str) or len(unit) > 4000 or not any(c.isalnum() for c in unit) for unit in units):
            raise ValueError('invalid_lyric_syllable_units')
        if ''.join(units) != sources[key]:
            raise ValueError('syllable_units_must_preserve_exact_plain_lyrics')
        count += len(units)
        if count > 4096:
            raise ValueError('lyric_syllable_limit')
    return value


def syllable_proposals(job, original, harmonic):
    """Group actual CTC character boundaries; missing characters are refused."""
    requested = validate_syllables(job.get('lyricSyllables', {}), job['cues'])
    views = [{row['cueId']: row['characters'] for row in result.get('characterTimings', [])}
             for result in (original, harmonic)]
    output, evidence = [], []
    for index, cue in enumerate(job['cues']):
        units = requested.get(cue['cueId'])
        if units is None:
            continue
        plain = plain_lyrics(cue['text'])
        rows = [view.get(cue['cueId'], []) for view in views]
        reason, proposed, cursor = None, [], 0
        if any(''.join(row['char'] for row in chars) != plain or any(len(row['char']) != 1 for row in chars) for chars in rows):
            reason = 'character_sequence_unavailable_or_changed'
        else:
            previous_end = [cue['startMs'], cue['startMs']]
            for unit in units:
                ends, scores = [], []
                for view, chars in enumerate(rows):
                    letters = [row for row in chars[cursor:cursor+len(unit)] if row['char'].isalnum()]
                    valid = bool(letters)
                    for row in letters:
                        a, b, score = row.get('startMs'), row.get('endMs'), row.get('score')
                        if (type(a) is not int or type(b) is not int or type(score) not in (int, float) or
                                not math.isfinite(score) or score < .35 or not previous_end[view] <= a < b <= cue['endMs']):
                            valid = False
                            break
                        previous_end[view] = b
                    if not valid:
                        reason = 'missing_low_score_or_nonmonotonic_character'
                        break
                    ends.append((letters[0]['startMs'], letters[-1]['endMs']))
                    scores.append(min(row['score'] for row in letters))
                if reason:
                    break
                if max(abs(a-b) for a, b in zip(ends[0], ends[1])) > 250:
                    reason = 'two_view_boundary_disagreement'
                    break
                proposed.append({'cueId': cue['cueId'], 'cueIndex': index+1, 'text': unit,
                    'startMs': ends[0][0], 'endMs': ends[0][1], 'confidence': min(1, *scores), 'unit': 'syllable'})
                cursor += len(unit)
        if reason is None:
            output.extend(proposed)
        evidence.append({'cueId': cue['cueId'], 'suppliedUnits': units, 'acceptedUnits': len(proposed) if reason is None else 0,
            'status': reason or 'user-segmentation-two-view-ctc-agreement-unqualified',
            'boundaryAgreementMs': 250, 'minimumCharacterScore': .35})
    return output, evidence


def pitch_evidence(job, audio, harmonic):
    """Monophonic F0 candidates only. Neither view isolates the singer."""
    import librosa
    import numpy as np
    cues = job['cues']
    if any(c['endMs']-c['startMs'] > 12000 for c in cues) or sum(c['endMs']-c['startMs'] for c in cues) > 120000:
        raise ValueError('lyric_pitch_limit_twelve_seconds_per_cue_two_minutes_total')
    evidence, retained = [], 0
    names = ('C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B')
    for cue in cues:
        start, end = cue['startMs'] * 16, cue['endMs'] * 16
        if end > len(audio):
            raise ValueError('lyric_pitch_cue_exceeds_audio')
        tracks = []
        for view in (audio, harmonic):
            samples = view[start:end]
            if len(samples) < 2048:
                tracks = []
                break
            tracks.append(librosa.pyin(samples, sr=16000, fmin=65, fmax=1000,
                frame_length=2048, hop_length=320, center=False, n_thresholds=32, fill_na=np.nan))
        notes, group, seen, accepted, omitted = [], [], 0, 0, 0
        def flush():
            nonlocal retained, omitted
            if len(group) < 5:
                group.clear()
                return
            if len(notes) >= 80 or retained >= 2000:
                omitted += 1
                group.clear()
                return
            midi = group[0][1]
            notes.append({'startMs': group[0][0]-10, 'endMs': group[-1][0]+10, 'midi': midi,
                'note': names[midi % 12] + str(midi // 12 - 1),
                'medianHz': round(float(np.median([entry[2] for entry in group])), 3),
                'minimumVoicedScore': round(min(entry[3] for entry in group), 4)})
            retained += 1
            group.clear()
        if len(tracks) == 2:
            for frame, (a, voiced_a, score_a, b, voiced_b, score_b) in enumerate(zip(
                    tracks[0][0], tracks[0][1], tracks[0][2], tracks[1][0], tracks[1][1], tracks[1][2])):
                seen += 1
                if (not voiced_a or not voiced_b or not np.isfinite([a, b, score_a, score_b]).all() or
                        min(score_a, score_b) < .8 or abs(1200 * math.log2(a / b)) > 50):
                    flush()
                    continue
                note = 69 + 12 * math.log2(a / 440)
                midi = round(note)
                if abs(note - midi) > .35:
                    flush()
                    continue
                at = cue['startMs'] + round((frame * 320 + 1024) / 16)
                if at - 10 < cue['startMs'] or at + 10 > cue['endMs']:
                    flush()
                    continue
                accepted += 1
                if group and (group[-1][1] != midi or at - group[-1][0] > 21):
                    flush()
                group.append((at, midi, float(a), float(min(score_a, score_b))))
            flush()
        evidence.append({'cueId': cue['cueId'], 'candidates': notes, 'analyzedFrames': seen,
            'agreedFrames': accepted, 'omittedCandidateGroups': omitted,
            'scope': 'uploaded-mix-not-verified-vocal-notes', 'algorithm': 'librosa.pyin',
            'version': librosa.__version__, 'sampleRate': 16000, 'frameSamples': 2048, 'hopSamples': 320,
            'minimumVoicedScore': .8, 'maximumViewDifferenceCents': 50, 'minimumCandidateMs': 100})
    return evidence
