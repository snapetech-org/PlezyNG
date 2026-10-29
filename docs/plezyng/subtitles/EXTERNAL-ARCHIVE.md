# Explicit external subtitle archive

Revision history now offers **External subtitle archive**. Choose an existing,
readable local directory such as `/mnt/datapool/subs`; saving also needs write
permission. The selection is remembered per profile on this device. Forgetting
the folder removes the preference and leaves every archived file intact.
Filesystem permission grants, mounts and directory-picker support remain
platform dependent; this path does not implement remote transport uploads,
Android document-provider URIs, iOS security-scoped bookmarks or a browser store.

**Save this item's reviewed history** loads the current bounded local revision
history and writes a new immutable snapshot below
`PlezyNG-subtitles-v1/<profile hash>/<history identity hash>/`. Each snapshot has
a `history.json` and a small `manifest.json` with a SHA-256 digest, actual byte
count, revision count, media title, creation time and local identity hash.
Transport URLs, credentials and raw server/item identifiers are excluded. Caption
text and the title are plain text in the selected folder; no encryption or
sender authentication is implied by the checksum.

Files are flushed into a random temporary directory beside the destination.
The root and managed ancestors are rechecked before a same-parent directory
rename publishes the snapshot. Existing snapshots and original subtitle files
are never replaced or automatically pruned. The operation is serialized within
this app process. Independent writers on a shared mount do not share a quota
lock; filesystem rename/flush semantics and power-loss durability need platform
qualification. Interrupted `.pending-*` directories are not offered for import
and count toward the profile quota until managed outside the app.

The reader lists only this profile and history identity, rejects links below
the chosen canonical root, bounds manifest/payload reads and verifies the
payload hash before parsing. Revision IDs must be unique and each record uses
the existing cue/timing validator. The review shows operation, cue count,
language, clock basis and text samples. The viewer must confirm the same media
cut/audio and choose one revision to import into local history. This does not
attach a track. Reopen revision history to review/attach through its existing
guarded path.

History identity is the existing profile/server/item/media-index binding; some
standalone sources include their file fingerprint. It is not a new content
fingerprint for library files. An unchanged server identity can still describe
replaced content, so identity lookup alone does not establish cut equivalence.
Cross-profile or cross-provider rebinding uses the existing explicit JSON
import, not automatic archive matching.

The archive preserves original cue IDs, word timings, language, operation and
file-versus-item clock. No part offset, local playback delay, renderer appearance
or device latency is baked into a snapshot. A new local history record is made
on import; its existing 12-revision/24-MiB retention policy still applies.

Bounds: 24 snapshots per item; 32 MiB per history payload; 8 MiB per revision;
16 KiB per manifest; 256 MiB and 6000 scanned filesystem entries per profile;
128 scanned directory entries per item. Limits include incomplete staging data.
Quota failures keep existing archives intact and ask the viewer to manage files
outside the app or choose another folder. Roots are trusted viewer-managed
directories, not a sandbox against hostile simultaneous filesystem changes.

Source integration confidence is moderate. No tests, analyzers, formatters,
builds, file-picker/runtime exercises or CI ran for this change. Filesystem,
permission, TV focus, large-text and platform behavior remain unqualified.
