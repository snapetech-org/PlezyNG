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
It is a supplied measurement, not independently collected playback, GPU, power
or latency telemetry. RTF coverage is explicit; paired differences use only
cases with both measurements. Lexical aggregates use only fully measured
baseline/candidate pairs. Failed/budget-limited cases remain in the report, and
the complete flag is false when any requested pair is unmeasured.

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
