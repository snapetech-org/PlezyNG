# Resumable source transcription

The AI sheet now queues either a retained WAV or the current complete VOD file
through its owning analysis transport. A source job uses the existing Android,
Apple or separate FFmpeg decoder; it does not change audible playback, output
mode or selected native tracks. The viewer explicitly chooses the file-order
audio ordinal and confirms the language/cut. This may use additional bandwidth
and the existing first-use local model download.

The job stores a digest of the transport's representation identity, duration,
part offset, explicit ordinal and selected-audio descriptor. It stores no URL,
cookie, transport credential or media path. This is a representation binding,
not a full-content hash of a remote file. A provider that replaces bytes without
changing identity or duration cannot be detected by this metadata alone.

The existing queue limits still apply: twelve jobs per profile, eight hours per
file, thirty-second checkpoint ownership with two-second overlap, 24 MiB text
output, 50,000 cues and 250,000 word timings. Source jobs retain one temporary
decoded window of at most 34 seconds, removed after inference, cancellation or
failure. Restart cleanup removes an interrupted window. They do not consume the
retained-WAV audio quota. Model admission and external-power/idle policies apply
before decoding and inference. Completed checkpoints are never recomputed merely
because playhead priority changes.

Source leases remain session-owned. File, audio or profile changes retire the
active window. Pausing, cancellation, deletion, completion, failure or leaving
the foreground closes the source capability. Resume requires opening the same
file and selected audio and obtaining a fresh matching lease; jobs are paused
after restart. No OS background execution entitlement is claimed. Native model
calls without interruption finish their current window before it is discarded.

Checkpoints use opened-file time. Review validates the current source binding,
then moves cues and word timings to item time once using the retained part
offset. Existing reviewed-result export/attachment converts to the opened part
as appropriate. Completed and partial results never attach automatically, and
unprocessed ranges remain visibly incomplete. WAV jobs and their schema-1
records remain supported. New records use schema 2.

Source and lifecycle logic was manually reviewed. No analyzer, formatter, test,
build, model execution or CI was run, as requested. Decoder/device behavior,
language quality and storage/power behavior remain unqualified.
