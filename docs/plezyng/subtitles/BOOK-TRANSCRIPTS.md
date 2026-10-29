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

Explicit JSON export is bounded to 16 MiB and records the book clock, part
offsets/durations, privacy-safe identity digests, selected revision/source-cue
IDs, file-local times, book times and canonical text. It is a separate
`plezyng.book-transcript.v1` export, not a single-file revision import or native
sidecar. Its complete flag means every file has selected cues, not that speech
coverage is verified. Word timings remain in the original per-file revisions.

Implementation confidence is moderate. No tests, analyzers, builds, source
execution, decoder/device qualification or CI ran. Backend seek support and
timestamp/narration accuracy still require qualification.
