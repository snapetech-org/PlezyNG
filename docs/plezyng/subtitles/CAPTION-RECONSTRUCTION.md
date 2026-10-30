# Burned-caption reconstruction preview

The optional `caption_reconstruct` companion task creates a separate derivative
from explicitly supplied matching file-clock cues, media, and a rectangular
mask. The app requires a checked acknowledgement before submission and allows a
half-second to thirty-second interval containing at most 120 cues. Cues crossing
the selected interval are clipped; the source media is never modified. The mask
may cover at most 20% of the image and is applied only while a supplied cue is
active. This task is distinct from the reversible app-screen cover band.

Local OpenCV Navier–Stokes spatial inpainting invents replacement pixels from the
mask boundary. It does **not** recover the original background, identify text,
track a moving mask, or provide a quality score. Large masks, moving pictures and
cuts can produce conspicuous smearing and flicker. The source must explicitly
declare unrotated square-pixel 8-bit BT.709 SDR; unknown color, HDR, high bit depth
and anamorphic/rotated inputs are refused. No remote model is used.

The output is a bounded, lossy MPEG-4 preview up to 960×540 at 12 fps. A selected
audio stream, when present, is converted to 48 kHz AAC stereo. This does not
preserve multichannel/object audio, source frame rate, native resolution or codec
fidelity. A clip-relative SRT retains the supplied wording, including previously
reviewed translations. Captions are separate from the video preview.

The authenticated, SHA-256-checked ZIP (maximum 32 MiB) contains `preview.mp4`,
`captions.srt`, `before.png`, `after.png`, `mask.png`, and `report.json`. The report
records the source digest, cue IDs, source/clip clock conversion, mask intervals,
frame count, algorithm and OpenCV version. Before/after evidence depicts the
first changed frame; the entire preview needs review. The app exposes research
provenance review and explicit ZIP export, then leaves playback unchanged.

Decoder/encoder concurrency is bounded, frame pipes retain one frame at a time,
processing has a three-minute deadline, and temporary video size is capped.
Probe and mux subprocesses have separate timeouts. Output duration is checked
after encoding and muxing so an encoder size cap cannot silently truncate a
successful result. Interrupted temporary products are removed on host recovery;
the normal job delete removes retained input and result.

API references: [OpenCV inpainting](https://docs.opencv.org/doc/doxygen/html/d7/d8b/group__photo__inpaint.html)
and [FFmpeg filters](https://ffmpeg.org/ffmpeg-filters.html). No video processing,
model, analyzer, fixture, test or build was run. Reconstruction quality and
decoder/encoder/platform behavior remain unqualified.
