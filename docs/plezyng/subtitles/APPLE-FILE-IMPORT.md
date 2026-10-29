# Apple subtitle document delivery

iOS/iPadOS and macOS register as alternate viewers for subtitle documents and
ZIP/TAR/gzip archives. The shared DeepLinkPlugin receives both cold scene opens
and subsequent file opens; ordinary Plezy links keep their existing delivery
coordinator. There is no new share extension or background download permission.
Plain TXT/XML remain available through the existing file picker; the app does
not advertise itself as a viewer for every text/XML document. A gzip input must
be named `.tar.gz`.

The native inbox acquires the URL's security scope before handing work to its
serial queue, coordinates a read, copies in 64 KiB blocks, and releases the
scope after copying. Only regular files are accepted. An immutable app-cache
copy is renamed into place after its declared length has been read. Size,
extension, admission and elapsed-copy limits are enforced; a blocked file
provider can still delay a synchronous native read. External provider URLs are
not persisted or sent to Dart. The native inbox holds at most 12 files / 128 MiB,
with 32 MiB per subtitle or 50 MiB per archive and seven-day expiry.

Dart copies into its existing bounded pending queue and acknowledges only IDs
that it retained. An engine restart can drain unacknowledged native files; a
crash between copy and acknowledgement does not duplicate the Dart import.
Each inbox has its own quota. Open documents remain pending when the Dart inbox
is full and are retried after the viewer takes the pending files. App caches
may be evicted by the OS, so this queue is not a permanent subtitle archive.

Source stems get distinct groups, retaining simultaneously opened IDX/SUB
companions without allowing equal basenames in different directories to
overwrite each other. A later open after acknowledgement receives a fresh ID.
Open both VobSub files together; opening the second file after consuming the
first does not infer a relationship to an earlier import. The player track
sheet exposes pending imports on supported Apple and Android backends. Import
and track choice remain explicit, with existing archive and format checks.

The Dart take operation now shares the same queue as file copies, so a new
arrival cannot race a queue clear. Android retains its existing share-intent
plugin; both platforms use the corrected staging and consumption rules.

Source review only. No build, analyzer, test, OS share-sheet, security-scope,
file-provider or device verification was run. Confidence in integration is
moderate; runtime behavior is unknown.
