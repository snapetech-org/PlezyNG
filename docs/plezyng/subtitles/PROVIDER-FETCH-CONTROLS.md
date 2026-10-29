# Subtitle provider retrieval controls

Automatic preferred-language retrieval now has one 12-second startup budget
covering search, download and discovery. Search waits are bounded to six seconds,
download waits to five seconds and catalog probes to three seconds, within that
shared budget. A visible startup action skips retrieval immediately. Supported
Plex/Jellyfin/Emby search and download requests use the existing HTTP transport's
abort controller; auxiliary source/catalog reads may finish after the caller has
stopped waiting, but cannot apply a retired result.

Profile changes, playback replacement, shutdown and disabling automatic
downloads retire the operation. Existing explicit-Off, server-selection, live,
offline and preferred-track guards still apply. Attempts are profile/source/
language scoped and bounded to the latest 64 keys in a playback screen. A new
playback attempt clears the previous status. Search failure, cancellation,
expiry and unavailable matches are visible in the subtitle track sheet, where
Search again opens the normal provider picker for an explicit choice. It does
not loop background downloads or change a viewer's intervening subtitle intent.

Discovery now polls the opened multipart file's item-clock origin when known.
Without a backend-reported downloaded stream ID, exactly one new external row
must match language and forced role before it can be selected automatically.
Concurrent ambiguous downloads stay available for explicit selection.

The ordinary server subtitle search sheet also cancels in-flight searches and
downloads, aborts them on close or replacement, and bounds waits to 15 and 20
seconds respectively. Results are guarded by request generation and profile.
Its retry action searches again. Once a download enters the existing guarded
native attachment path, the transport cancel control disappears.

Cancellation cannot undo a request already accepted by a remote server. The
server may retain the downloaded sidecar; the UI says so. No server-side delete
is attempted, and an obsolete request cannot choose a local track.

Source review only. No HTTP request, test, analyzer, formatter, build or device
run was performed. Confidence in integration is moderate; runtime is unknown.
