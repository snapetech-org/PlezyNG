"""Bounded summaries of explicitly supplied observations, never device probes.

No transcript text, observation IDs, trace clock IDs or device IDs enter the
report. Labels and clock correspondence remain assertions of the input author.
"""
from __future__ import annotations

import math
import re
import statistics


def integer(value, low, high):
    if type(value) is not int or not low <= value <= high:
        raise ValueError('diagnostic_integer_out_of_bounds')
    return value


def number(value, low, high):
    if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
        raise ValueError('diagnostic_number_out_of_bounds')
    return value


def identity(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', value):
        raise ValueError('diagnostic_identity_invalid')
    return value


def sequence(value, maximum):
    if not isinstance(value, list) or len(value) > maximum or any(not isinstance(v, dict) for v in value):
        raise ValueError('diagnostic_observation_limit_or_type')
    return value


def distribution(values):
    ordered = sorted(values)
    return {'observations': len(ordered), 'medianMs': statistics.median(ordered) if ordered else None,
            'p95Ms': ordered[math.ceil(len(ordered) * .95) - 1] if ordered else None}


class DiagnosticBudget:
    def __init__(self):
        self.cells = 0

    def distance(self, left, right):
        cells = len(left) * len(right)
        if cells > 4_000_000 or self.cells + cells > 32_000_000:
            raise ValueError('streaming_edit_distance_budget')
        self.cells += cells
        if len(right) > len(left):
            left, right = right, left
        previous = list(range(len(right) + 1))
        for i, a in enumerate(left, 1):
            current = [i]
            for j, b in enumerate(right, 1):
                current.append(min(previous[j] + 1, current[-1] + 1, previous[j - 1] + (a != b)))
            previous = current
        return previous[-1]


def streaming(reference, output, budget):
    truth, trace = reference.get('streamingReference'), output.get('streamingTrace')
    if truth is None or trace is None:
        return {'status': 'not-measured-missing-streaming-trace-or-reference'}
    if not isinstance(truth, dict) or not isinstance(trace, dict):
        raise ValueError('streaming_trace_must_be_object')
    if identity(truth.get('clockId')) != identity(trace.get('clockId')):
        raise ValueError('streaming_clock_identity_mismatch')
    horizon = integer(truth.get('observationEndMs'), 1, 7 * 86400000)
    events = sequence(truth.get('events'), 10000)
    if not events:
        raise ValueError('streaming_reference_requires_events')
    state = {}
    for event in events:
        key = identity(event.get('id'))
        onset = integer(event.get('onsetMs'), 0, horizon)
        end = integer(event.get('endMs'), onset + 1, horizon)
        cancelled = event.get('cancelledAtMs')
        if cancelled is not None:
            integer(cancelled, onset, horizon)
        if key in state:
            raise ValueError('streaming_event_identity_duplicate')
        state[key] = {'onset': onset, 'end': end, 'cancelled': cancelled, 'words': [], 'committed': 0,
                      'seen': False, 'finalized': False, 'first': None, 'draft': None, 'final': None}
    observations = sequence(trace.get('observations'), 50000)
    last_at, edits, revisions, changed_committed, after_final, final_regressions, stale, unknown = -1, 0, 0, 0, 0, 0, 0, 0
    for observation in observations:
        key = identity(observation.get('eventId'))
        at = integer(observation.get('atMs'), 0, horizon)
        if at < last_at:
            raise ValueError('streaming_observations_must_be_chronological')
        last_at = at
        text = observation.get('text')
        if not isinstance(text, str) or len(text) > 4000:
            raise ValueError('streaming_text_limit')
        words = text.split()
        committed = integer(observation.get('committedWords'), 0, len(words))
        final = observation.get('final')
        if type(final) is not bool:
            raise ValueError('streaming_final_flag_required')
        current = state.get(key)
        if current is None:
            unknown += 1
            continue
        if current['cancelled'] is not None and at >= current['cancelled']:
            stale += 1
            continue
        if current['first'] is None and words:
            current['first'] = at
        if current['draft'] is None and words and not final:
            current['draft'] = at
        if current['final'] is None and words and final:
            current['final'] = at
        if current['seen']:
            if words != current['words']:
                revisions += 1
                edits += budget.distance(current['words'], words)
                after_final += int(current['finalized'])
            if committed < current['committed'] or words[:current['committed']] != current['words'][:current['committed']]:
                changed_committed += 1
            if current['finalized'] and not final:
                final_regressions += 1
        current.update(words=words, committed=committed, seen=True, finalized=current['finalized'] or final)
    completed = [v for v in state.values() if v['cancelled'] is None]
    first = [v['first'] - v['onset'] for v in completed if v['first'] is not None]
    draft = [v['draft'] - v['onset'] for v in completed if v['draft'] is not None]
    final = [v['final'] - v['end'] for v in completed if v['final'] is not None]
    return {'status': 'measured', 'referenceEvents': len(state), 'completedReferenceEvents': len(completed),
            'cancelledReferenceEvents': len(state) - len(completed), 'observations': len(observations),
            'missingFirstText': len(completed) - len(first), 'missingNonemptyFinal': len(completed) - len(final),
            'firstTextFromOnset': distribution(first), 'firstDraftFromOnset': distribution(draft),
            'firstFinalFromSpeechEnd': distribution(final), 'textBeforeOnset': sum(v < 0 for v in first),
            'finalBeforeSpeechEnd': sum(v < 0 for v in final), 'revisions': revisions, 'revisionWordEdits': edits,
            'committedPrefixViolations': changed_committed, 'textChangesAfterFinal': after_final,
            'finalFlagRegressions': final_regressions, 'observationsAfterCancellation': stale,
            'unmatchedObservations': unknown,
            'textPolicy': 'case-sensitive whitespace words; first emission is not a revision; no semantic correctness inferred'}


def calibration(output):
    value = output.get('confidenceReview')
    if value is None:
        return {'status': 'not-measured-missing-confidence-review'}
    if not isinstance(value, dict) or value.get('unit') not in {'word', 'token', 'cue'}:
        raise ValueError('confidence_review_unit_required')
    policy = identity(value.get('labelPolicy'))
    # Store a digest of the policy in the report, not an arbitrary user label.
    import hashlib
    observations = sequence(value.get('observations'), 50000)
    if not observations:
        raise ValueError('confidence_review_requires_labels')
    seen, bins, brier, loss, impossible = set(), [[0, 0., 0] for _ in range(10)], 0., 0., 0
    for observation in observations:
        key = identity(observation.get('id'))
        if key in seen:
            raise ValueError('confidence_review_duplicate_identity')
        seen.add(key)
        score = number(observation.get('score'), 0, 1)
        correct = observation.get('correct')
        if type(correct) is not bool:
            raise ValueError('confidence_review_boolean_label_required')
        target = int(correct)
        bucket = bins[min(9, int(score * 10))]
        bucket[0] += 1; bucket[1] += score; bucket[2] += target
        brier += (score - target)**2
        probability = score if correct else 1 - score
        if probability == 0:
            impossible += 1
        else:
            loss -= math.log(probability)
    count = len(observations)
    return {'status': 'measured', 'unit': value['unit'], 'labelPolicySha256': hashlib.sha256(policy.encode()).hexdigest(),
            'observations': count, 'meanScore': sum(v[1] for v in bins) / count,
            'observedAccuracy': sum(v[2] for v in bins) / count, 'brierScore': brier / count,
            'negativeLogLikelihood': None if impossible else loss / count,
            'zeroProbabilityContradictions': impossible,
            'expectedCalibrationError10EqualWidthBins': sum(abs(v[1] - v[2]) for v in bins) / count,
            'bins': [{'lowerInclusive': i / 10, 'upperExclusiveExceptLast': (i + 1) / 10, 'count': v[0],
                      'meanScore': v[1] / v[0] if v[0] else None, 'observedAccuracy': v[2] / v[0] if v[0] else None}
                     for i, v in enumerate(bins)],
            'labelSource': 'supplied reviewer labels; correctness and independence not verified'}


def telemetry(output):
    value = output.get('telemetry')
    if value is None:
        return {'status': 'not-measured-missing-telemetry'}
    if not isinstance(value, dict) or value.get('scope') not in {'process', 'device'}:
        raise ValueError('telemetry_scope_required')
    identity(value.get('clockId'))
    horizon = integer(value.get('observationEndMs'), 1, 7 * 86400000)
    samples = sequence(value.get('samples'), 50000)
    if not samples:
        raise ValueError('telemetry_requires_samples')
    last, memory, powers, thermal, frame_rows = -1, [], [], {}, []
    for sample in samples:
        at = integer(sample.get('atMs'), 0, horizon)
        if at <= last:
            raise ValueError('telemetry_samples_must_be_strictly_chronological')
        last = at
        if 'residentBytes' in sample:
            memory.append(integer(sample['residentBytes'], 0, 16 * 1024**4))
        if 'powerMilliwatts' in sample:
            powers.append((at, number(sample['powerMilliwatts'], 0, 10_000_000)))
        if 'thermalState' in sample:
            thermal_state = sample['thermalState']
            if not isinstance(thermal_state, str) or thermal_state not in {'nominal', 'fair', 'serious', 'critical', 'unknown'}:
                raise ValueError('telemetry_thermal_state_invalid')
            thermal[thermal_state] = thermal.get(thermal_state, 0) + 1
        if 'droppedFrames' in sample or 'renderedFrames' in sample:
            frame_rows.append((at, integer(sample.get('droppedFrames'), 0, 10**12),
                               integer(sample.get('renderedFrames'), 0, 10**12)))
    energy, covered, gaps = 0., 0, 0
    for a, b in zip(powers, powers[1:]):
        interval = b[0] - a[0]
        if interval > 5000:
            gaps += 1
            continue
        covered += interval
        energy += (a[1] + b[1]) * .5 * interval / 1_000_000
    dropped, rendered, frame_covered, resets = 0, 0, 0, 0
    for a, b in zip(frame_rows, frame_rows[1:]):
        if b[1] < a[1] or b[2] < a[2]:
            resets += 1
            continue
        dropped += b[1] - a[1]; rendered += b[2] - a[2]; frame_covered += b[0] - a[0]
    if not memory and not powers and not thermal and not frame_rows:
        return {'status': 'not-measured-no-telemetry-values', 'samples': len(samples)}
    return {'status': 'measured', 'scope': value['scope'], 'samples': len(samples), 'observationEndMs': horizon,
            'residentSamples': len(memory), 'observedResidentPeakBytes': max(memory) if memory else None,
            'powerSamples': len(powers), 'powerCoveredMs': covered, 'powerCoverage': covered / horizon,
            'powerGapsOverFiveSeconds': gaps, 'integratedEnergyJoules': energy if covered else None,
            'thermalSampleCounts': thermal, 'frameCounterSamples': len(frame_rows), 'frameCounterResetIntervals': resets,
            'frameCounterCoveredMs': frame_covered, 'droppedFramesDelta': dropped if frame_covered else None,
            'renderedFramesDelta': rendered if frame_covered else None,
            'droppedFraction': dropped / (dropped + rendered) if dropped + rendered else None,
            'measurementSource': 'supplied trace; observer, attribution and collection overhead not verified'}


def diagnostics(reference, output, budget):
    reports = {}
    for name, measure in [('streaming', lambda: streaming(reference, output, budget)),
                          ('calibration', lambda: calibration(output)), ('telemetry', lambda: telemetry(output))]:
        try:
            reports[name] = measure()
        except (ValueError, TypeError, KeyError, OverflowError) as error:
            reason = str(error)
            reports[name] = {'status': 'not-measured-invalid',
                             'reason': reason if re.fullmatch(r'[a-z_]{1,100}', reason) else type(error).__name__}
    return reports
