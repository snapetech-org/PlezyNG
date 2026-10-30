# Reviewed sign-region motion

The companion signs flow accepts a normalized rectangular crop, independently
controlling left, top, width and height. A host with local OpenCV can advertise
an optional motion switch. The input must finish within two minutes; OCR refuses
an extra frame beyond that bound before tracking starts. At most 120 emitted
one-second-or-longer OCR cues are processed.

After 2 Hz OCR produces wording, timing and representative image proposals,
the local 12 Hz forward/backward feature tracker follows texture inside the
selected crop. Existing cut/flash, round-trip, inlier, scale, angle and frame-edge
gates end unreliable paths. It never reacquires a lost sign or claims semantic
identity. Cues longer than twelve seconds continue in bounded windows seeded
from the preceding observed rectangle; those restart boundaries remain evidence.

The result retains every observed rectangle and window status. Only a complete
sample grid replaces the selected region with its fixed spatial envelope.
Incomplete paths retain the selected crop. App captions stay stable inside a
cue; they do not animate along the path. Background texture can dominate the
tracker, so complete coverage is not a confidence or correctness score.

Source images and motion evidence must pass the existing separate research and
image/text review. JSON export preserves paths and provenance; an owned multipart
source shifts cue, image, observation, window and sample times by the same part
offset exactly once. SRT continues to flatten position. The companion job owns
these samples; revision history retains accepted cue regions, not the full
experimental path.

No OCR, optical flow, model, test or build was run. Recognition, sign identity,
tracking accuracy and device behavior remain unqualified.
