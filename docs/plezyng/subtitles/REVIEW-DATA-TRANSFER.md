# Reviewed subtitle data transfer

Playback settings and portable caption defaults expose a review-data dialog.
It exports reviewed translation suggestions and hidden provider-revision hashes
as a bounded JSON file. The file is plaintext and can contain source and
translated dialogue, opaque media-item identifiers, and source/context hashes;
the dialog discloses this before export. It contains no transport configuration,
credential, model file or active-track selection. New translation-memory entries
include a bounded source-line preview; older entries remain importable without
that preview. A canonical payload SHA-256 detects corruption; it does not
authenticate the sender.

Opening a file only previews it. Translation conflicts show current and incoming
text, default to keeping local text, and require an individual incoming choice
before import. New entries are merged after an explicit import action. The
normal translation flow still checks exact source/context/language/backend/
glossary fingerprints and requires review before attachment. Moving memory does
not establish model-version compatibility or language quality. Hidden provider
revisions import separately, with their original expiry; source/server/item
identity must match for a revision to affect another device's search.

Memory retains its 2,000-entry / 2 MiB bound. Hidden revisions retain their
256-entry / 180-day bound. The combined transfer is capped at 2 MiB + 64 KiB,
with bounded streaming reads and a 20-second elapsed deadline. An import that
would exceed a store's bound is refused instead of evicting unrelated local
data. Each import checks a preview digest against the current store and refuses
concurrent edits. Writes remain serialized and profile-bound; memory replacement
has recovery rollback if its final rename fails.

New hidden revisions are profile-local. Their identity no longer includes a
provider result's row number, which could change when search order changed.
Legacy device-wide data had no profile owner, so it is retained separately and
can be previewed and explicitly imported into a selected profile. Its old keys
remain readable for matching result metadata; restoring a result removes both
old and new keys. There is no automatic assignment of legacy data to a viewer.

This implements explicit cross-device file transfer. It does not schedule cloud
uploads or reconcile deletions between devices. Existing paired caption/default
cloud flows remain separate. New controls use centralized English fallback.

No test, analyzer, formatter, build, file picker, network transfer or inference
was executed. Source integration confidence is moderate; runtime is unknown.
