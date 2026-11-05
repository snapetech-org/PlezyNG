# Podcast client behavior

RSS/Atom subscriptions share the source vault, index, downloads and player.
Audiobookshelf podcast libraries retain their server-specific behavior.

## Discovery and automatic downloads

Connected RSS feeds are checked at startup and roughly every 30 minutes while
PlezyNG is in the foreground. A rotating batch of at most 50 shows bounds each
pass. A durable baseline prevents notifications for old episodes on the first
refresh. Per-show notifications are opt-in and use the existing Android/iOS
notification capability; an unavailable notification route does not block feeds.

The Podcasts menu exposes per-show download rules: keep the latest 0–50
unfinished episodes, require Wi-Fi/Ethernet, and optionally remove finished
downloads after a chosen number of days. Automatic downloads require a declared
enclosure length and allow at most 512 MiB per show per UTC day. Existing download
storage quotas and free-space reserves still apply. Unknown-size episodes remain
available for manual download. Native download jobs retain their existing OS
scheduling; closed-app feed polling is not promised.

Retention applies to files claimed in the automation journal. Manual download
requests are protected independently. Active playback and profile/lifecycle
changes stop retention work. Disabling a rule retains its existing files; it
does not grant deletion of manually downloaded media or history.

## Archives and transcripts

Feed documents are limited to 6 MiB and 10,000 items; larger documents fail rather
than silently truncate an index. Episode pages contain at most 250 items. Atom
`prev-archive` and `next` links can traverse up to 64 documents; cycles fail the
scan before deletion reconciliation. Four archive documents are cached in memory.
Resource locators and cursors are encrypted with the source owner's vault and
validated against profile, source and feed identity. They are excluded from
edition fingerprints, preserving resume state through token rotation.

Podcast Namespace transcripts support WebVTT, SRT, JSON segments, plain text and
inert HTML-to-text conversion. Open the transcript action on episode details.
Timed text is searchable and can seek the currently playing audio episode.
Fetched transcripts are cached encrypted for offline use and can be removed from
the transcript screen. Resources are limited to 2 MiB and 20,000 cues; plain text
is limited to 512 KiB. Opening a transcript never executes publisher HTML.

## gpodder-compatible synchronization

Open Podcasts → gpodder-compatible sync. Enter the HTTPS server URL, username
and password, choose subscription/progress sync, review what the server receives,
then connect. Credentials, checkpoints, deferred actions and conflicts are
encrypted locally. Feed and episode URLs, including membership tokens, are sent
to the chosen server as required by the gpodder API. Authentication stays on that
server and never follows redirects or travels to a publisher/CDN.

Every installation has a unique device ID. Link the devices using the server's
device synchronization controls for shared subscription changes. Listening
actions are account-wide. HTTPS subscriptions can be imported automatically;
HTTP imports remain deferred for manual source setup. Remote unsubscribe defers
while playback is active and retains existing offline files and history.

Known-duration RSS episodes synchronize resume position, completion and reset
through API v2 episode actions. Unknown-duration progress remains local until a
duration is available. Active sessions are never overwritten. Concurrent local
and remote changes remain visible as a conflict; choose the device to retain.
Conflict choices check both the displayed local revision and remote value.

The gpodder acknowledgment table is separate from publication cloud/provider
acknowledgments. A delayed response cannot acknowledge a newer local revision.
GET cursors advance only after incoming changes are handled or durably deferred;
POST cursors cannot skip an intervening remote change. URL rewrite mappings are
retained. Network retries may repeat idempotent absolute state.

API replies/checkpoints are bounded to 2 MiB, subscription deltas to 500 URLs,
pending actions to 5,000 and conflicts to 2,000. Accounts exceeding these bounds
report a failure and retain their previous cursor. No history is silently
discarded to make a checkpoint fit.

Protocol references: [gpodder.net API](https://gpoddernet.readthedocs.io/en/latest/api/),
[RFC 5005](https://www.rfc-editor.org/rfc/rfc5005.html), and the
[Podcast Namespace](https://github.com/Podcastindex-org/podcast-namespace).

Source regressions cover private archive restart, stable identity, transcripts,
authentication/redirect scope, cursor regression, revision acknowledgments and
database migration. Flutter/native/server/device execution remains pending.
