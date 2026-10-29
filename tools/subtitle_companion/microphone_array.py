"""Explicit raw-array far-field candidates; never interpret a soundtrack as an array.

No learned model, source identity inference, channel remixing or resampling.
Coordinates and latency/polarity calibration are user declarations, not verified.
"""
from __future__ import annotations
import hashlib
import json
import math
import wave
from collections import Counter

MAX_INPUT_BYTES = 100 * 1024**2


def validate(value, cues):
    if not isinstance(value, dict) or value.get('schema') != 'plezyng.microphone-array.v1' or value.get('rawSynchronizedCapture') is not True:
        raise ValueError('declare_original_synchronized_microphone_capture')
    if value.get('axes') != 'x-right-y-forward-z-up':
        raise ValueError('declare_microphone_array_axes')
    speed = value.get('speedOfSoundMps')
    if type(speed) not in (int, float) or not math.isfinite(speed) or not 300 <= speed <= 380:
        raise ValueError('invalid_declared_sound_speed')
    channels = value.get('channels')
    if not isinstance(channels, list) or not 4 <= len(channels) <= 8:
        raise ValueError('microphone_array_requires_four_to_eight_channels')
    clean = []
    for channel in channels:
        if not isinstance(channel, dict): raise ValueError('invalid_microphone_channel')
        position, delay, polarity = channel.get('positionM'), channel.get('delayUs'), channel.get('polarity')
        if (not isinstance(position, list) or len(position) != 3 or
                any(type(n) not in (int, float) or not math.isfinite(n) or abs(n) > 2 for n in position) or
                type(delay) not in (int, float) or not math.isfinite(delay) or abs(delay) > 5000 or
                type(polarity) is not int or polarity not in (-1, 1)):
            raise ValueError('invalid_microphone_position_latency_or_polarity')
        clean.append({'positionM': list(position), 'delayUs': delay, 'polarity': polarity})
    if (not 1 <= len(cues) <= 60 or any(c['endMs']-c['startMs'] > 12000 or c['endMs'] > 120000 for c in cues) or
            sum(c['endMs']-c['startMs'] for c in cues) > 120000):
        raise ValueError('array_limit_sixty_cues_twelve_seconds_each_two_minutes_total')
    return {'schema': 'plezyng.microphone-array.v1', 'axes': value['axes'],
        'rawSynchronizedCapture': True, 'speedOfSoundMps': speed, 'channels': clean}


def _pair_delay(np, spectra, block, i, j, rate, fft_size, distance, speed, electronic):
    cross = spectra[:, j] * spectra[:, i].conj()
    magnitude = np.abs(cross)
    frequencies = np.fft.rfftfreq(fft_size, 1/rate)
    band = (frequencies >= 300) & (frequencies <= min(6000, rate*.45))
    if not band.any() or magnitude[band].max() <= 1e-12: return None, 'no_band_energy'
    weighted = np.where(band, cross / np.maximum(magnitude, magnitude[band].max()*1e-6), 0)
    correlation = np.fft.irfft(weighted, n=fft_size)
    bound = distance/speed
    first = math.floor((electronic-bound)*rate)-1
    last = math.ceil((electronic+bound)*rate)+1
    lags = np.arange(first, last+1)
    peaks = correlation[lags % fft_size]
    best = int(np.argmax(peaks))
    peak = float(peaks[best])
    if peak <= 0: return None, 'no_positive_peak'
    outside = np.abs(lags-lags[best]) > max(2, math.ceil(rate*.0002))
    alternative = max(0.0, float(peaks[outside].max())) if outside.any() else peak
    ratio = peak/max(alternative, 1e-12)
    if ratio < 1.25: return None, 'ambiguous_delay_peak'
    lag = float(lags[best])
    if 0 < best < len(peaks)-1:
        a, b, c = map(float, peaks[best-1:best+2])
        denominator = a-2*b+c
        if denominator < -1e-12:
            lag += max(-.5, min(.5, .5*(a-c)/denominator))
    delay = lag/rate-electronic
    if abs(delay) > bound + 1/rate: return None, 'delay_outside_geometry'
    integer = round(lag)
    if integer >= 0: one, two = block[integer:, j], block[:len(block)-integer, i]
    else: one, two = block[:len(block)+integer, j], block[-integer:, i]
    denominator = math.sqrt(float(np.dot(one, one)*np.dot(two, two)))
    coherence = float(np.dot(one, two))/denominator if denominator > 1e-12 else 0.0
    if coherence < .35: return None, 'weak_aligned_correlation'
    return (delay, ratio, coherence), None


def run(folder, job, progress):
    import numpy as np
    config = validate(job.get('microphoneArray'), job['cues'])
    positions = np.asarray([c['positionM'] for c in config['channels']], dtype=np.float64)
    delays = np.asarray([c['delayUs'] for c in config['channels']], dtype=np.float64)*1e-6
    polarity = np.asarray([c['polarity'] for c in config['channels']], dtype=np.float32)
    speed = config['speedOfSoundMps']
    pairs = [(i, j) for i in range(len(positions)) for j in range(i+1, len(positions))]
    distances = [float(np.linalg.norm(positions[j]-positions[i])) for i, j in pairs]
    matrix = np.asarray([-(positions[j]-positions[i])/speed for i, j in pairs])
    if (min(distances) < .03 or max(distances) > 2 or np.linalg.matrix_rank(matrix) != 3 or
            float(np.linalg.cond(matrix)) > 30):
        raise ValueError('array_requires_distinct_well_conditioned_noncoplanar_geometry')
    calibration_digest = hashlib.sha256(json.dumps(config, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    evidence = []
    source_path = folder/'input.media'
    if source_path.stat().st_size > MAX_INPUT_BYTES:
        raise ValueError('array_wav_exceeds_100_mib')
    with wave.open(str(source_path), 'rb') as source:
        rate, channels, frames = source.getframerate(), source.getnchannels(), source.getnframes()
        if (source.getcomptype() != 'NONE' or source.getsampwidth() != 2 or channels != len(positions) or
                not 16000 <= rate <= 48000 or not 0 < frames <= 120*rate):
            raise ValueError('array_requires_matching_pcm_sixteen_bit_wav_up_to_two_minutes')
        duration = math.floor(frames*1000/rate)
        if max(c['endMs'] for c in job['cues']) > duration: raise ValueError('array_cues_exceed_uploaded_capture')
        frame, hop = round(rate*.256), round(rate*.128)
        fft_size = 1 << (2*frame-1).bit_length()
        window = np.hanning(frame).astype(np.float32)[:, None]
        inverse = np.linalg.pinv(matrix)
        for cue_index, cue in enumerate(job['cues']):
            progress(folder, 'Estimating declared-array directions; retain wording', cue_index/len(job['cues']))
            first, until = math.ceil(cue['startMs']*rate/1000), math.floor(cue['endMs']*rate/1000)
            accepted, vectors, rejected = [], [], Counter()
            attempted = 0
            for at in range(first, until-frame+1, hop):
                attempted += 1
                source.setpos(at)
                raw = source.readframes(frame)
                if len(raw) != frame*channels*2: raise ValueError('array_capture_truncated')
                block = np.frombuffer(raw, dtype='<i2').reshape(frame, channels).astype(np.float32)/32768
                if (np.abs(block) >= .995).mean(axis=0).max() > .005:
                    rejected['clipping'] += 1; continue
                block *= polarity
                block -= block.mean(axis=0)
                if float(np.sqrt((block*block).mean(axis=0)).min()) < 1e-4:
                    rejected['insufficient_energy'] += 1; continue
                spectra = np.fft.rfft(block*window, n=fft_size, axis=0)
                observed, ratios, coherences = [], [], []
                failure = None
                for (i, j), distance in zip(pairs, distances):
                    result, failure = _pair_delay(np, spectra, block, i, j, rate, fft_size,
                        distance, speed, delays[j]-delays[i])
                    if failure: break
                    observed.append(result[0]); ratios.append(result[1]); coherences.append(result[2])
                if failure: rejected[failure] += 1; continue
                vector = inverse @ np.asarray(observed)
                norm = float(np.linalg.norm(vector))
                if not .75 <= norm <= 1.25: rejected['not_consistent_with_far_field'] += 1; continue
                vector /= norm
                residual = float(np.sqrt(np.mean((matrix @ vector-np.asarray(observed))**2)))
                if residual > max(1.5/rate, 20e-6): rejected['inconsistent_pair_delays'] += 1; continue
                vectors.append(vector)
                accepted.append({'startMs': round(at*1000/rate), 'endMs': round((at+frame)*1000/rate),
                    'azimuthDegrees': round(math.degrees(math.atan2(vector[0], vector[1])), 2),
                    'elevationDegrees': round(math.degrees(math.asin(float(np.clip(vector[2], -1, 1)))), 2),
                    'fitResidualUs': round(residual*1e6, 2), 'minimumPeakRatio': round(min(min(ratios), 1000), 3),
                    'minimumAlignedCorrelation': round(min(coherences), 3)})
            summary = None
            if len(vectors) >= 3 and len(vectors) >= attempted*.3:
                mean = np.mean(vectors, axis=0)
                concentration = float(np.linalg.norm(mean))
                if concentration >= .8:
                    mean /= concentration
                    summary = {'azimuthDegrees': round(math.degrees(math.atan2(mean[0], mean[1])), 2),
                        'elevationDegrees': round(math.degrees(math.asin(float(np.clip(mean[2], -1, 1)))), 2),
                        'directionConcentration': round(concentration, 3)}
            kept = accepted if len(accepted) <= 32 else [accepted[round(i*(len(accepted)-1)/31)] for i in range(32)]
            evidence.append({'cueId': cue['cueId'], 'status': 'unqualified-direction-candidate' if summary else 'no-stable-direction',
                'summary': summary, 'attemptedWindows': attempted, 'acceptedWindows': len(accepted),
                'rejectedWindows': dict(rejected), 'windows': kept, 'omittedWindowEvidence': len(accepted)-len(kept)})
    return {'cues': job['cues'], 'sourceCues': job['cues'], 'wordTimings': [], 'durationMs': duration,
        'language': job.get('language') or 'unknown', 'model': 'bounded-GCC-PHAT-far-field-v1',
        'soundLocalizationEvidence': {'calibrationDigest': calibration_digest, 'declaredCalibration': config,
            'sampleRate': rate, 'coordinateFrame': 'array-relative; azimuth zero forward, positive right; elevation positive up',
            'windowMs': 256, 'hopMs': 128, 'qualified': False, 'cues': evidence},
        'warnings': ['Requires original synchronized microphone channels and correct measured geometry, polarity and latency. These declarations were not independently verified.',
            'Directions use a single dominant far-field source assumption. Reflections, near-field sources, simultaneous speakers, channel processing and clock drift can defeat it.',
            'Candidates are in the declared array coordinate frame. They do not identify a speaker, a visible object or a world location, and do not change caption wording or timing.',
            'Peak ratios, fit residuals and directional concentration are consistency diagnostics, not calibrated probabilities or angular error bounds. No hardware or accuracy qualification was run.']}
