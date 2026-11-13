# App-managed media download lifecycle

The app-managed media queue uses `download_queue` for executable and deferred
supplementary work, `downloaded_media` for the durable media state, and the
`video_downloads` background task group for native transfers. The publication
source queue has a separate profile-scoped ledger; see
[`docs/sources/QUALIFICATION.md`](../sources/QUALIFICATION.md).

Native callbacks are accepted only when their task ID still matches the
download row. Pausing is asynchronous, so it changes a row to `paused` only
while the row remains `queued` or `downloading`. If that matching native task
finishes during the request, its completion is still accepted from `paused`
and the completed file remains available offline. A pause must not erase a
terminal result or discard deferred supplementary-download intent.

This is an implementation invariant, not a claim of physical-device
qualification.
