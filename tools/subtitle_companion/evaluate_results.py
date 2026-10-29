#!/usr/bin/env python3
"""Compare supplied subtitle results; never run models or activate a candidate.

Input files remain local. Word error uses whitespace tokens; character error
uses normalized Unicode code points excluding whitespace. Explicit cue pairs
are required for timing; lexical similarity never fabricates a timing match.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import math
from pathlib import Path
import re
import statistics
import unicodedata

from evaluate_diagnostics import DiagnosticBudget, diagnostics


MAX_FILE = 8 * 1024**2
MAX_TOTAL = 64 * 1024**2
MAX_CELLS = 20_000_000
MAX_TOTAL_CELLS = 100_000_000


def integer(value, minimum, maximum):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError('integer_out_of_bounds')
    return value


class Inputs:
    def __init__(self, root):
        self.root = root.resolve()
        self.bytes = 0
        self.cells = 0
        self.hashes = {}
        self.diagnostic_budget = DiagnosticBudget()

    def read(self, name):
        if not isinstance(name, str) or not name or len(name) > 1024 or Path(name).is_absolute():
            raise ValueError('use_relative_input_paths')
        path = (self.root / name).resolve(strict=True)
        if not path.is_relative_to(self.root) or not path.is_file():
            raise ValueError('input_outside_manifest_directory')
        with path.open('rb') as source:
            data = source.read(MAX_FILE + 1)
        if not data or len(data) > MAX_FILE or self.bytes + len(data) > MAX_TOTAL:
            raise ValueError('input_byte_budget')
        self.bytes += len(data)
        digest = hashlib.sha256(data).hexdigest()
        if name in self.hashes and self.hashes[name] != digest:
            raise ValueError('input_changed_during_evaluation')
        self.hashes[name] = digest
        return json.loads(data.decode('utf-8'))

    def distance(self, reference, hypothesis):
        cells = len(reference) * len(hypothesis)
        if cells > MAX_CELLS or self.cells + cells > MAX_TOTAL_CELLS:
            raise ValueError('edit_distance_budget')
        self.cells += cells
        if len(reference) < len(hypothesis):
            reference, hypothesis = hypothesis, reference
        previous = list(range(len(hypothesis) + 1))
        for i, left in enumerate(reference, 1):
            current = [i]
            for j, right in enumerate(hypothesis, 1):
                current.append(min(previous[j] + 1, current[-1] + 1, previous[j - 1] + (left != right)))
            previous = current
        return previous[-1]


def transcript(value, normalization, duration):
    if not isinstance(value, dict):
        raise ValueError('result_must_be_object')
    cues = value.get('cues', [])
    if not isinstance(cues, list) or len(cues) > 50000:
        raise ValueError('cue_limit')
    by_id, texts = {}, []
    for cue in cues:
        if not isinstance(cue, dict) or not isinstance(cue.get('text'), str) or len(cue['text']) > 4000:
            raise ValueError('invalid_cue_text')
        start, end = integer(cue.get('startMs'), 0, 7 * 86400000), integer(cue.get('endMs'), 0, 7 * 86400000)
        identity = cue.get('cueId')
        if end <= start or end > duration or not isinstance(identity, str) or not 1 <= len(identity) <= 128 or identity in by_id:
            raise ValueError('invalid_cue_identity_or_time')
        by_id[identity] = cue
        texts.append(cue['text'])
    text = value.get('text', '\n'.join(texts))
    if not isinstance(text, str) or len(text) > 1_000_000:
        raise ValueError('transcript_text_limit')
    # Consume an explicit text field when present; otherwise serialize cues in
    # supplied order, including overlap. No automatic speaker reconciliation.
    text = re.sub(r'<(?:rt|rp)\b[^>]*>.*?</(?:rt|rp)>', '', text, flags=re.I | re.S)
    text = re.sub(r'<[^>]*>|\{[^}]*\}', '', text).replace(r'\N', '\n')
    text = html.unescape(text)
    if normalization == 'nfkc_casefold':
        text = unicodedata.normalize('NFKC', text).casefold()
    elif normalization != 'exact':
        raise ValueError('unknown_normalization')
    return text.split(), [c for c in text if not c.isspace()], by_id


def percentile(values, quantile):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * quantile) - 1)]


def timing(reference, output, pairs):
    if pairs is None:
        return {'status': 'not-measured-no-explicit-pairs'}
    if not isinstance(pairs, list) or len(pairs) > 50000:
        raise ValueError('timing_pair_limit')
    seen_reference, seen_output, starts, ends = set(), set(), [], []
    for pair in pairs:
        if not isinstance(pair, dict):
            raise ValueError('invalid_timing_pair')
        a, b = pair.get('referenceCueId'), pair.get('outputCueId')
        if (not isinstance(a, str) or not isinstance(b, str) or a not in reference or b not in output or
                a in seen_reference or b in seen_output):
            raise ValueError('timing_pairs_must_be_explicit_unique_existing_ids')
        seen_reference.add(a)
        seen_output.add(b)
        starts.append(output[b]['startMs'] - reference[a]['startMs'])
        ends.append(output[b]['endMs'] - reference[a]['endMs'])
    return {'status': 'measured' if pairs else 'not-measured-empty-pairs', 'pairs': len(pairs),
            'unpairedReferenceCues': len(reference) - len(seen_reference), 'unpairedOutputCues': len(output) - len(seen_output),
            'startSignedMedianMs': statistics.median(starts) if starts else None,
            'endSignedMedianMs': statistics.median(ends) if ends else None,
            'startAbsoluteP95Ms': percentile([abs(v) for v in starts], .95),
            'endAbsoluteP95Ms': percentile([abs(v) for v in ends], .95),
            'bothEdgesWithin250Ms': sum(abs(a) <= 250 and abs(b) <= 250 for a, b in zip(starts, ends))}


def score(inputs, reference, value, duration, normalization, reference_value):
    words, characters, cues = transcript(value, normalization, duration)
    a, b, _ = reference
    elapsed = value.get('inferenceWallMs')
    if elapsed is not None:
        integer(elapsed, 0, 7 * 86400000)
    return {'wordEdits': inputs.distance(a, words), 'referenceWords': len(a), 'hypothesisWords': len(words),
            'characterEdits': inputs.distance(b, characters), 'referenceCharacters': len(b),
            'inferenceWallMs': elapsed, 'realTimeFactor': elapsed / duration if elapsed is not None else None,
            'timing': timing(reference[2], cues, value.get('timingPairs')),
            'diagnostics': diagnostics(reference_value, value, inputs.diagnostic_budget)}


def rates(row):
    return {**row, 'wer': row['wordEdits'] / row['referenceWords'] if row['referenceWords'] else None,
            'cer': row['characterEdits'] / row['referenceCharacters'] if row['referenceCharacters'] else None}


def summarize(rows, model):
    selected = [row[model] for row in rows if row.get('status') == 'measured-pair']
    totals = {key: sum(row[key] for row in selected) for key in
              ['wordEdits', 'referenceWords', 'hypothesisWords', 'characterEdits', 'referenceCharacters']}
    # Paired cases only, even when one side succeeded before the other failed.
    return rates({**totals, 'pairedCases': len(selected),
                  'timedCases': sum(row['realTimeFactor'] is not None for row in selected),
                  'emptyReferenceWordsWithOutput': sum(row['referenceWords'] == 0 and row['hypothesisWords'] > 0 for row in selected),
                  'rtfMedian': statistics.median([row['realTimeFactor'] for row in selected if row['realTimeFactor'] is not None])
                  if any(row['realTimeFactor'] is not None for row in selected) else None})


def evaluate(inputs, manifest):
    if not isinstance(manifest, dict) or manifest.get('schema') != 'plezyng.subtitle-evaluation.v1':
        raise ValueError('unsupported_manifest')
    normalization = manifest.get('normalization', 'exact')
    if normalization not in {'exact', 'nfkc_casefold'}:
        raise ValueError('unknown_normalization')
    required_diagnostics = manifest.get('requiredDiagnostics', [])
    if (not isinstance(required_diagnostics, list) or len(required_diagnostics) > 3 or
            any(not isinstance(v, str) or v not in {'streaming', 'calibration', 'telemetry'} for v in required_diagnostics) or
            len(set(required_diagnostics)) != len(required_diagnostics)):
        raise ValueError('invalid_required_diagnostics')
    cases = manifest.get('cases')
    if not isinstance(cases, list) or not 1 <= len(cases) <= 1000:
        raise ValueError('case_limit')
    rows, identities, references = [], set(), set()
    for case in cases:
        if not isinstance(case, dict):
            raise ValueError('invalid_case')
        identity = case.get('id')
        if not isinstance(identity, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', identity) or identity in identities:
            raise ValueError('case_identity_must_be_unique')
        identities.add(identity)
        row = {'id': identity}
        try:
            duration = integer(case.get('audioDurationMs'), 1, 86400000)
            reference_name = case.get('reference')
            reference_value = inputs.read(reference_name)
            reference_digest = inputs.hashes[reference_name]
            row['referenceContentRepeated'] = reference_digest in references
            references.add(reference_digest)
            reference = transcript(reference_value, normalization, duration)
            for model in ('baseline', 'candidate'):
                row[model] = rates(score(inputs, reference, inputs.read(case.get(model)), duration, normalization, reference_value))
            row['status'] = 'measured-pair'
        except (ValueError, OSError, UnicodeError, TypeError, KeyError) as error:
            row['status'] = 'not-measured'
            # Do not copy filesystem paths, source text or credentials from an
            # exception into a shareable evaluation report.
            row['reason'] = str(error) if isinstance(error, ValueError) and re.fullmatch(r'[a-z_]{1,100}', str(error)) else type(error).__name__
        rows.append(row)
    baseline, candidate = summarize(rows, 'baseline'), summarize(rows, 'candidate')
    paired = baseline['pairedCases']
    diagnostic_coverage = {name: {model: sum(row.get('status') == 'measured-pair' and
        row[model]['diagnostics'][name]['status'] == 'measured' for row in rows) for model in ('baseline', 'candidate')}
        for name in ('streaming', 'calibration', 'telemetry')}
    paired_diagnostics = {name: sum(row.get('status') == 'measured-pair' and all(
        row[model]['diagnostics'][name]['status'] == 'measured' for model in ('baseline', 'candidate')) for row in rows)
        for name in diagnostic_coverage}
    rtf_deltas = [row['candidate']['realTimeFactor'] - row['baseline']['realTimeFactor'] for row in rows
                  if row.get('status') == 'measured-pair' and row['baseline']['realTimeFactor'] is not None and
                  row['candidate']['realTimeFactor'] is not None]
    return {'schema': 'plezyng.subtitle-evaluation-report.v1', 'qualification': 'not-established',
            'manifestSchema': manifest['schema'], 'normalization': normalization,
            'lexicalPolicy': 'cue order or explicit text; markup/ruby readings removed; whitespace words; non-whitespace Unicode code points; punctuation retained',
            'inputHashes': {hashlib.sha256(name.encode()).hexdigest(): digest for name, digest in sorted(inputs.hashes.items())},
            'casesRequested': len(cases), 'pairedCasesMeasured': paired, 'lexicallyComplete': paired == len(cases),
            'complete': paired == len(cases) and all(paired_diagnostics[name] == len(cases) for name in required_diagnostics),
            'requiredDiagnostics': required_diagnostics, 'diagnosticCoverage': diagnostic_coverage,
            'pairedDiagnosticCases': paired_diagnostics,
            'baseline': baseline, 'candidate': candidate,
            'pairedWerDelta': candidate['wer'] - baseline['wer'] if baseline['wer'] is not None else None,
            'pairedCerDelta': candidate['cer'] - baseline['cer'] if baseline['cer'] is not None else None,
            'pairedRtfCases': len(rtf_deltas), 'pairedRtfDeltaMedian': statistics.median(rtf_deltas) if rtf_deltas else None,
            'cases': rows, 'limits': {'inputBytes': inputs.bytes, 'editDistanceCells': inputs.cells,
                                    'streamingEditDistanceCells': inputs.diagnostic_budget.cells},
            'warnings': ['Only fully measured baseline/candidate pairs enter aggregates; inspect omitted cases before comparing.',
                'Empty references retain insertion counts; their individual error rates are undefined, not zero.',
                'Repeated reference text is flagged, not treated as proof that audio recordings are duplicated or independent.',
                'Whitespace WER is not linguistically segmented WER for every script. Cue order does not solve overlapping-speaker scoring.',
                'Timing matches are supplied correspondences, not independently verified alignment or coverage.',
                'Inference wall time and input duration are supplied measurements, not independent device telemetry.',
                'Optional streaming clocks, confidence correctness labels and device/process telemetry are supplied observations, not independently collected evidence.',
                'Diagnostic coverage counts do not establish comparable units, collection policy, devices or operating conditions; inspect each case before comparison.',
                'No held-out independence, causal quality gain, device qualification or model promotion is established by this report.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    manifest_path = args.manifest.resolve(strict=True)
    inputs = Inputs(manifest_path.parent)
    manifest = inputs.read(manifest_path.name)
    report = evaluate(inputs, manifest)
    encoded = json.dumps(report, ensure_ascii=False, indent=2).encode('utf-8')
    if len(encoded) > 16 * 1024**2:
        raise ValueError('report_byte_limit')
    # Exclusive creation prevents an evaluation from overwriting an original,
    # its manifest or an earlier report. The caller chooses the destination.
    with args.report.open('xb') as destination:
        destination.write(encoded)
    if not report['complete']:
        raise SystemExit(2)


if __name__ == '__main__':
    main()
