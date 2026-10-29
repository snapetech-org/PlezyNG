# Book-wide transcript view

Source-player audiobooks with a complete duration map can combine saved revisions
on the current queue's book clock. The view is available for ordinary owned
source sessions, not transient URLs, live inputs, sample previews or unrelated
music engines. It requires at most 256 files and a total duration of seven days.

Each file loads revisions from its existing profile/source/item/file-fingerprint
identity. The viewer explicitly selects a revision and confirms the narration,
edition and clock basis. File-local timestamps are the default used by standalone
transcription. An explicit book-clock switch subtracts that part's current queue
offset before validation. Every cue must fit entirely inside the file; there is
no silent clipping or guessed alignment. A selected file replaces only its own
rows in the combined view. Missing files remain visible.

The view searches up to 50000 cues / 5 MiB of text, supports spoiler hiding and
copies plain text. A seek goes through the owning source command queue and
preserves play/pause state. Its validity check runs inside that queue so a delayed
action cannot seek a later book. Profile/source/edition/order/fingerprint/duration
changes invalidate the snapshot and hide its data; changing the current file
within the same book is allowed. The combined view does not attach a native
subtitle or overwrite any saved revision.

The dialog labels, tooltips and typed action errors use the shared English
fallback catalog. Translation review remains open.

Explicit JSON export is bounded to 16 MiB and records the book clock, part
offsets/durations, privacy-safe identity digests, selected revision/source-cue
IDs, file-local times, book times and canonical text. It is a separate
`plezyng.book-transcript.v1` export, not a single-file revision import or native
sidecar. Its complete flag means every file has selected cues, not that speech
coverage is verified. Word timings remain in the original per-file revisions.

Implementation confidence is moderate. No tests, analyzers, builds, source
execution, decoder/device qualification or CI ran. Backend seek support and
timestamp/narration accuracy still require qualification.

## Whole-book generation

The book transcript dialog can explicitly queue every file in the captured
source order. Each file must have a known duration up to eight hours; a book is
bounded to 256 files and seven days. The viewer confirms a file-order audio
ordinal for every file, with optional spoken-language override and local speech
provider. Stream numbers are not inferred from native track IDs and do not prove
matching narration across files.

`SubtitleBookGeneration` opens a separate source capability for each file,
including eligible cached/local/network sources. It does not seek, reload or
change audible playback. One ordinary source transcription job runs at a time,
using the existing power, idle, model-admission and thirty-second checkpoint
policies. Playback can advance within the same book. A different edition, queue
order, duration, source identity or profile pauses the batch. Leaving the app
foreground also pauses it; restart and recovery require explicit resume.

Completed files become digest-bound **unaccepted** results in a separate batch
store. The result and batch cursor are durably written before deleting the file
job's checkpoints. File clocks and original word timings remain intact. Each
file is reviewed explicitly before saving an accepted revision to its existing
history; generation never attaches or selects captions. Empty recognition is
recorded separately and is not evidence of absent speech.

The store allows four batches per profile, 64 MiB committed results per batch
and 8 MiB per result, plus one temporary result during commit. Batches consume
one slot in the twelve-job queue. Source WAV windows remain temporary. A missing,
cancelled or failed file job pauses progress rather than silently discarding its
partial work or retrying forever. A crash between job creation and cursor commit
can leave an independently visible paused job in Transcription jobs; its saved
windows remain available there. Deleting a batch removes its pending results
and active job; accepted revision history is separate.

The UI and lifecycle paths were manually reviewed; no runtime, tests, build,
analyzer, formatter, model or CI execution occurred. Native decoding, language
quality, restart behavior and storage/power performance remain unqualified.
