# Model-score review

The subtitle AI sheet offers an optional per-profile review threshold: disabled
by default, or 0.30, 0.50, 0.70 or 0.90. It is a local review preference, not a
playback filter, automatic rejection rule or change to the model. Profiles load
their own setting; writes are serialized by the control and report persistence
failure without pretending the preference was saved. Profile-less sessions can
use a temporary threshold.

Results with linked word/token/alignment records expose the lowest and mean
finite score in each cue and a count of scored spans. A cue is flagged if at least
one linked span falls strictly below the selected threshold. The review opens a
searchable virtualized editor with a flag-only switch, existing text/time edits,
draft persistence and undo. The normal editor can show all cues, including those
without scores. Nothing is discarded or automatically attached by this feature.

Scores are **uncalibrated**, differ across providers and are not interchangeable
with human correctness labels. Whisper word records may already average several
tokens. A high score does not establish the right words, language, timing or
speaker; no linked score means unknown, not perfect or failed recognition.
Explicit cue IDs take precedence, ambiguous/unknown IDs cannot borrow another
cue's score, and evidence must overlap its linked cue. Nonfinite/out-of-range
scores are omitted. Bounds remain 50,000 cues and 250,000 timed spans.

Text or timing edits invalidate the displayed original score. Undo to exactly
the original cue can reveal it again; editing does not invent a score for the
new wording. Original word timings retain their existing acceptance/export
invalidation rules. The review policy does not add a calibration claim to JSON,
history, live captions or provider metadata. The result preview and editor use
scrollable content so their evidence and controls are reachable on small views.

The existing multilingual Whisper and English-only accelerator model contracts
remain explicit. Language override is separate; this change neither detects
language uncertainty nor supplies language-specific trained models. No tests,
model execution, analyzer/formatter, build or CI dispatch was performed.
