# Supplied-result evaluation

`tools/subtitle_companion/evaluate_results.py` provides an offline, dependency-free
comparison of supplied reference, baseline and candidate JSON results. It runs
no recognizer, downloads no model, sends no data, changes no player and activates
no model. This tool was written but not executed in the code-only pass; no
evaluation result or quality improvement is claimed.

The manifest uses paths relative to its own directory. Resolved inputs must
remain inside that directory, including through symlinks. An illustrative
manifest (not evaluation evidence) is:

```json
{
  "schema": "plezyng.subtitle-evaluation.v1",
  "normalization": "exact",
  "cases": [{
    "id": "speech_001",
    "audioDurationMs": 30000,
    "reference": "references/speech_001.json",
    "baseline": "baseline/speech_001.json",
    "candidate": "candidate/speech_001.json"
  }]
}
```

Each result may provide explicit `text`, or `cues` with unique `cueId`, `startMs`,
`endMs` and `text`. Cue times must fit the declared audio interval. In the absence
of an explicit transcript, text follows the supplied cue order; overlapping
speakers are not automatically reconciled. Markup and ruby readings are removed,
entities decoded, and punctuation retained. `exact` retains case/Unicode form;
`nfkc_casefold` explicitly applies compatibility normalization and case folding.

Word error uses whitespace-delimited tokens. Character error uses non-whitespace
Unicode code points. Neither is a claim of linguistic word segmentation for all
scripts. Empty-reference insertions remain visible; per-case error rates with a
zero denominator are null. Repeated reference text is flagged without assuming
that separate recordings are duplicates or independent.

To measure timing, each baseline/candidate result must include explicit
`timingPairs`, for example `[{"referenceCueId":"r1","outputCueId":"c1"}]`.
IDs must exist and be unique on both sides. Reports include unpaired counts,
signed median and absolute p95 boundary errors, and how many pairs place both
edges within 250 ms. Missing pairs mean unmeasured timing, not zero error.
These correspondences need independent review; text similarity never creates a
timing match.

Optional `inferenceWallMs` yields a real-time factor against `audioDurationMs`.
It is a supplied measurement, separate from the optional streaming and resource
traces below. RTF coverage is explicit; paired differences use only
cases with both measurements. Lexical aggregates use only fully measured
baseline/candidate pairs. Failed/budget-limited cases remain in the report, and
the complete flag is false when any requested pair is unmeasured. Optional
diagnostic failures preserve lexical scores and show their own missing/invalid
status. The manifest can declare `requiredDiagnostics` as any distinct subset of
`["streaming", "calibration", "telemetry"]`; then `complete` additionally requires
those measurements on both sides of every case. `lexicallyComplete` remains
separate. Neither flag establishes quality or qualification.

Bounds are 1000 cases of up to 24 hours, 8 MiB per file / 64 MiB total reads, 50000 cues and one
million text code points per result, 20 million edit-distance cells per metric /
100 million total cells, and a 16 MiB report. Source text and filesystem paths
are omitted from reports; case IDs and hashes remain. Choose non-sensitive case
IDs before sharing. Reports are exclusively created and never overwrite an
input or prior report. An incomplete comparison exits with status 2 after
writing the report.

```sh
python tools/subtitle_companion/evaluate_results.py \
  --manifest /path/to/evaluation/manifest.json \
  --report /path/to/evaluation/comparison.json
```

Implementation confidence is moderate. Held-out independence, human transcript
quality, confidence calibration, playback deadlines, thermal/power behavior,
semantic quality, device qualification and release acceptance require separate
evidence. The report always says `qualification: not-established`; it never
auto-promotes a model or declares a research feature production-ready.

## Streaming observations

The reference may include `streamingReference` with a clock ID, observation end,
and explicitly identified speech events. The baseline and candidate include
their own `streamingTrace` on that same declared clock. Times are milliseconds
on the observer's monotonic arrival/display timeline, **not media PTS**. A trace
must be collected with known audio-arrival and caption-display correspondence;
renaming media times or model inference durations does not establish latency.
For example, these are schema illustrations, not measurement results:

```json
{
  "streamingReference": {
    "clockId": "recording_a",
    "observationEndMs": 30000,
    "events": [{"id": "speech_a", "onsetMs": 1000, "endMs": 2500}]
  }
}
```

```json
{
  "streamingTrace": {
    "clockId": "recording_a",
    "observations": [
      {"eventId": "speech_a", "atMs": 2100, "text": "Example", "committedWords": 0, "final": false},
      {"eventId": "speech_a", "atMs": 3000, "text": "Example words", "committedWords": 2, "final": true}
    ]
  }
}
```

The report gives median/p95 first text and first draft after speech onset, first
nonempty final after speech end, and explicit missing-event counts at the end of
observation. Negative values remain visible and have separate before-onset/end
counts; they must not be interpreted as successful low-latency recognition.
Reference events can supply `cancelledAtMs`; later observations are counted as
stale and excluded from that event's latency. Cancelled events are reported
separately from completed speech. Unknown event IDs remain unmatched counts.

Stability uses case-sensitive whitespace words. It counts text revisions and
word edit distance between successive emissions, committed-prefix changes or
retreats, text changes after a final result and final-flag regressions. The first
emission is not a revision. These are mechanical stability measures, not semantic
correctness, calibrated confidence or proof of suitable on-screen segmentation.
Reference and output correspondence is explicit; the tool does not guess it.

Bounds are 10000 reference events, 50000 chronological observations, 4000 code
points per observation, seven days of observer time, four million distance cells
per revision and 32 million cells across all streaming diagnostics. Its distance
budget is separate from the lexical comparison budget. IDs and transcript text
are omitted from the report.

## Supplied confidence labels

A result may include `confidenceReview`, with unit `word`, `token` or `cue`, a
stable non-sensitive `labelPolicy`, and up to 50000 uniquely identified reviewed
observations. Each contains `id`, a finite `score` between zero and one, and an
explicit Boolean `correct` label. For example:

```json
{"confidenceReview":{"unit":"word","labelPolicy":"verbatim_word_v1","observations":[
  {"id":"word_a","score":0.75,"correct":true}
]}}
```

Reports contain the mean score, observed accuracy, mean squared probability
error (Brier score), negative log likelihood and ten equal-width calibration
bins. Expected calibration error is the count-weighted absolute difference
between each nonempty bin's mean score and observed accuracy. Score 1 belongs
to the final bin. A zero probability assigned to the supplied correct outcome
makes negative log likelihood null with an explicit contradiction count, rather
than silently clipping the probability. The policy is retained as a digest.

Labels need independent human review. Unit, policy, sample selection, language,
and dataset comparability are not inferred. No calibration curve is fitted or
activated, and no calibration error is pooled across incompatible cases.

## Supplied resource traces

A result may include `telemetry` with `scope` (`process` or `device`), `clockId`,
`observationEndMs`, and at most 50000 strictly chronological `samples`. Each
sample has `atMs` and any available `residentBytes`, `powerMilliwatts`,
`thermalState`, or paired cumulative `droppedFrames` / `renderedFrames` counters.
Frame counts must be disjoint dropped and rendered counts, not total submitted
frames labeled as rendered. Thermal values are nominal/fair/serious/critical/
unknown; platform-specific scales require an explicitly documented collector.

The report retains sampled peak resident bytes and thermal sample counts.
Power uses trapezoidal integration only between samples at most five seconds
apart; gaps and coverage are explicit, with no extrapolation to the observation
boundaries. Frame deltas omit intervals containing counter resets and show
covered time. An all-zero delta has undefined drop fraction; missing counters
are not zero drops. Missing resources remain null or empty with sample counts.
Timestamp-only samples are not a measured telemetry result.

Device energy includes unrelated work; process samples depend on the collector's
definition. Neither proves subtitle-only resource consumption, GPU operator
placement, memory between samples, thermal safety or uninterrupted playback.
The evaluator does not run a collector, exercise playback or verify the origin
of supplied labels/traces. Diagnostic coverage is reported for each model and
for pairs; heterogeneous metrics are not averaged into one performance score.
