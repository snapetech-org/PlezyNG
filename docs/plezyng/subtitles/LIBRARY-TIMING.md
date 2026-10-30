# Library copy and track timing

The library player's audio, primary-subtitle and secondary-subtitle sync bars
offer an explicit bookmark button to save the currently applied timing for the
current profile, represented file and selected tracks. Primary subtitle delay
and drift multiplier are saved together. Removing that record restores the
existing scoped preference for that lane. Subsequent edits to a saved binding
update that record instead of changing the broad scope setting.

The identity includes server/item, authoritative version and opened part,
available file size/duration/path metadata, source stream descriptors, native
backend/catalog and selected audio. Each subtitle lane additionally binds its
own subtitle descriptor. Transcoded playback requires the source audio stream
ID; burned-in subtitles have no native subtitle binding. Missing or ambiguous
version/part identity leaves the ordinary scoped controls available without
offering a copy-specific save. Signed URL query/user-info/fragment fields are
excluded. Only digests and bounded numeric timing records are persisted.

This is **representation metadata identity**, not a digest of the remote video
or subtitle bytes. An in-place replacement with identical metadata is not
detectable here. Library corrections now have a separate explicit, bounded JSON
file transfer that requires the exact represented copy, backend and selected
tracks; it does not auto-publish or change live playback. See
[NATIVE-TIMING-TRANSFER.md](NATIVE-TIMING-TRANSFER.md). Remote subtitle content
receipts remain separate work. The existing standalone asset path retains its
stronger downloaded-subtitle content digest. Existing global/library/title
settings are not migrated or erased; unmatched records fall back to them.

There are at most 300 records and 256 KiB per profile, with oldest records
evicted on explicit saves. Writes serialize and recheck profile/source/track
ownership at persistence. A fresh player open, source/cut/track change or
profile retirement selects only matching records. Independent lane keys avoid
resetting the other lane's session adjustment when its binding did not change.

Native restoration and sync controls share the same per-player/property queue.
Already dispatched writes finish before restoration; stale queued edits and
rollback/preview operations cannot target a new media generation or selection.
Saving from the bookmark action waits for the existing manual-edit queue.
Closing the player releases stream/profile listeners. No network request or
server preference write is part of saving a local timing correction.

Manual source review only: no tests, analyzer, formatter, build or CI was run.
Source integration confidence is moderate; runtime behavior is unknown.
