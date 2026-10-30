# Native subtitle correction transfer

Library primary/secondary subtitle sync controls now expose a bounded JSON
transfer dialog when the current copy and track selection have a native timing
binding. Export captures the currently confirmed delay and, for the primary
lane, timestamp multiplier. Audio output delay is excluded. The file carries
only a schema, opaque binding digest, property, opened-file clock and numeric
correction. There are no profile IDs, paths, URLs, credentials or subtitle words.

Import is limited to one regular file of at most 4 KiB. Its property, clock,
schema, numeric bounds and exact current binding must match. The dialog previews
current playback, the previously saved record and the incoming correction. An
explicit save writes only the copy-specific record for the next media open or
track restoration; it does not mutate current playback or broad scoped defaults.
An undo action restores the prior record, including the absence of one.

Import and undo compare the expected saved value **inside** the existing
serialized correction-write queue. A concurrent saved edit is retained. The
profile, playback generation and selected tracks are rechecked at persistence.
Changing tracks invalidates the dialog. It never automatically rebinds a file to
a similar-looking media item, different backend or renamed native stream.

The binding uses server representation and track metadata, not a content hash.
An in-place replacement with identical metadata is undetectable. Consequently
this transfer requires the same stable catalogue on both devices; it cannot
bridge arbitrary server copies or backend track numbering. Standalone managed
subtitle assets retain their existing content-bound corrections and corrected
sidecar export path. There is no automatic publication of native corrections.

No fixture, test, analyzer, build or native playback was run. Timing, persistence
and device behavior remain unqualified.
