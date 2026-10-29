# Whole-file scene proposals

The companion `scene_track` task uses the configured, manifest-verified local
DETR CPU pack across a chosen video, independently of the optional remote scene
review provider. The app exposes it in Companion processing. The upload remains
explicit, bounded to 1 GiB, with at most 5000 matching file-clock subtitle cues.
The first video stream must have a usable declared duration of at most eight
hours. Caption wording and cue times are returned unchanged.

The worker decodes one 640×360 RGB frame per second into a bounded pipe. It keeps
at most 48 recent anonymous tracks, using detector class, box overlap and color
histogram agreement. Ambiguous associations are refused. Cut/flash gates clear
the active tracks, and a three-second maximum gap ends old associations.
Undetected positions are not interpolated. Reacquisition is a proposal, not
verified identity or proof that an object persisted through an occlusion.

Every observed frame goes into `scene-tracks.jsonl`, capped at 32 MiB. The header
declares the source digest, model fingerprint, labels, coordinate/tuple schema
and resampled source clock. Rows contain time, scene number, anonymous track ID,
detector category/score and normalized observed boxes. Scores are not calibrated
accuracy. No video images or audio are sent to another provider.

At every 60 frames the worker fsyncs the observation log and atomically saves
its committed prefix length/digest, active appearance histograms, cut-gate
thumbnail and cue-region accumulators. Resume verifies the input/request/model,
declared duration and log prefix before truncating an uncommitted tail. It can
redo up to 59 frames. Cancellation uses the existing worker process-tree owner;
the four-hour worker wall-time limit remains in effect, and a later explicit
resume uses the checkpoint. No runtime or throughput promise is made.

Each cue receives envelopes only for tracks observed at least twice while that
cue was active, with at most 12 regions. At most 64 simultaneously active cues
are accepted. Omitted proposals, sample coverage, gaps, cuts and refused matches
remain visible in the review summary. The app can export the length/digest-
checked JSONL log and separately preview/use those regions with its existing
opt-in scene-avoidance placement. Downloading evidence never applies a caption
track or changes playback. Audio/WAV artifact handling remains a separate type.

The full declared frame grid is required; early/truncated decode fails instead
of reporting a completed scan. FFmpeg's fixed-rate sampling can duplicate or
drop frames, and one frame per second misses short shots and objects. Thus
`frameGridComplete` is coverage of that sampling contract, not full semantic
understanding, exact source-frame PTS, occlusion correctness or qualification.
Long-lived reidentification across cuts is intentionally absent.

Sources for the underlying APIs: [FFmpeg fps filter](https://ffmpeg.org/ffmpeg-filters.html#fps)
and [OpenCV histogram comparison](https://docs.opencv.org/4.x/d8/dc8/tutorial_histogram_comparison.html).
No model, parser, test, build, analyzer or CI was run for this change. Source
integration confidence is moderate; scene quality and runtime are unknown.
