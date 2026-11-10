# Music details, history, pairing and shortcuts

These controls use the existing profile-owned music session. They do not grant
access to another account's libraries, share credentials with a paired endpoint,
or establish complete Plexamp parity.

## Credits and smart playlists

Open **Music details** from a music item's context menu to view the fields its
authorized server actually supplies: separate credited roles, release date,
label, edition and media versions. Different recordings are not merged because
their titles happen to match. Missing provider data is not fabricated.

Music home exposes a Plex smart-playlist editor. Existing playlists are refreshed
from their owning server before editing, including
[Plex directory URI rules](https://developer.plex.tv/pms/). The advanced query
preserves repeated parameters, exact operators, relative dates and nested
groups. The filter form can add a condition using the rule's source kind.
Preview queries the server; saving creates or updates the server's rule-based
playlist instead of freezing a local list. Grouping, sorting and limits remain
query rules.
Save-as creates a separate smart playlist. Backend permission failures remain
failures. Local finite download stations are a different feature.

## History and conflicting offline edits

Music history is profile-owned listening history, paged by occurrence rather than
deduplicated by track. New database writes refresh the loaded window without
resetting it to the first page.

Use the server button in Recently Played to browse playback history for a
visible music library on an owned Plex server. Pleazyng only enables this when
the active Plex identity is the verified account owner. Pages come from the
[Plex Media Server API](https://developer.plex.tv/pms/).
Provider plays are not inserted into local listening history, charts or paired
sync: the server does not expose Pleazyng occurrence IDs or listened duration
for a safe merge. Direct, shared and managed bindings without a verified owner
identity do not expose the server view.

The music-home Sync action shows conflicting offline rating/favorite decisions.
Choose the reviewed local or remote value explicitly. A stale conflict revision
cannot overwrite a newer decision; an already-applied remote value clears its
pending edit without another write. Server APIs do not provide atomic
compare-and-set, so simultaneous changes between a read and write are not
claimed to be transactional.

## Paired synchronization

1. Configure and authorize both app instances normally, then pair them using the
   existing companion remote flow. Both must advertise music group version 1.
2. Start a music queue, then select **Sync** in Now Playing. Select the existing
   control peer or add discovered receivers and enter each receiver's pairing
   code when requested. Up to sixteen additional receiver connections can be
   active alongside the existing control peer.
3. The receiver validates its own library access and prepares the queue paused.
   Playback starts following only after clock sampling and source preparation.
4. Use the initiating device for group transport. Remove a receiver independently
   without disconnecting siblings, or use Stop to leave all groups.

Each receiver has an independent authenticated channel, clock and heartbeat.
This is distinct from **transfer**, which pauses
the sender only after receiver acknowledgement. The initiating group device
keeps playing. Selecting a control target by itself starts neither operation.

Groups preserve duplicate queue occurrences, cursor, repeat and shuffle state for
the shared snapshot. Snapshots are bounded to 128 entries. Queue/mode replacement
ends the group; restart explicitly with the changed queue. A receiver-side local
transport/queue edit takes ownership rather than being overwritten by the next
anchor. Profile/account changes or missing heartbeats retire the group. Only the
leader records progress/listening history, avoiding duplicate group scrobbles.

Synchronization uses monotonic clock-offset/round-trip samples and one-second
sequenced anchors, seeking when drift exceeds 250 ms. It is not sample-accurate
multi-room audio: decoder/DAC/acoustic latency is not calibrated. Plexamp protocol
interoperability and acoustic multi-device qualification are not claimed.

## Android widget

Install the app internally, configure a profile and start music before adding
the home-screen music widget. Android widgets are not supported from adopted or
removable app storage. Transport uses the same queue/session as the app and
rejects intents from a previous profile or queue revision. No stream credentials
or durable track metadata are stored by the widget. If the process has no live
music session, tapping opens the app instead of silently restoring playback.

## iOS widget

Add the Pleazyng widget to the Home Screen in a signed build that includes it.
Small and medium widgets show the current track and artist; interactive play,
pause, previous and next controls require iOS 17 or newer. Tapping the widget
body opens the app. Transport only controls a running, unlocked profile session
with the same queue revision; it never starts playback from a cached queue.

The shared widget snapshot contains display text and an opaque session/revision,
not media URLs, server credentials, track IDs or profile identities. The app
clears the snapshot on session close and startup, and displayed metadata expires
after fifteen minutes without a refresh. iOS controls when timelines redraw.

Signed Store archives embed `org.snapetech.pleazyng.MusicWidgetExtension` when
`IOS_MUSIC_WIDGET_PROVISIONING_PROFILE_BASE64` is configured. The host and
extension profiles must both include `group.org.snapetech.pleazyng`; the extension
uses its own validated profile. Existing profiles without a widget profile still
produce the normal app without the widget. The archive verifies the exported
extension's bundle identifier. Signed installation and on-device interaction
qualification remain pending.

## Android NFC

On NFC-capable Android devices, open music details and select the NFC-writing
action. Hold a writable tag near the device until Saved appears, or cancel the
scan. Capacity, read-only tags, unsupported tags and the scan deadline can cause
a write to fail; success is shown only after the native write completes.
Use **Scan NFC tag** in Music home for an explicit foreground read. A cancelled
reader operation cannot deliver a tag to its replacement.

The NDEF record contains only a `pleazyng://play` link with server/item identity,
never a server token, media URL or account credentials. Scanning resolves that
identity against the currently authorized profile. A tag is not an access grant.
Tags are not permanently locked by the writer. Physical tag qualification remains.

## iPhone NFC

On a compatible iPhone, use **Scan NFC tag** in Music home or the NFC-writing
action in Music details. The foreground system scan accepts the same durable
server/item links as Android without embedding tokens or profile selection.
The app resolves scanned links through the active profile; a profile switch
during scanning discards the result. There is no background custom-scheme tag
launch on iOS.

The iOS Store archive enables Core NFC when the verified Runner provisioning
profile grants the `TAG` reader entitlement. For a local signed Xcode build,
enable the Near Field Communication Tag Reading capability for Runner, include
`Runner/MusicNFC.entitlements` (or merge its reader entitlement into the app's
existing entitlements), and set `PLEAZYNG_MUSIC_NFC_ENABLED=YES` in the Runner
configuration. Unsupported devices and unprovisioned builds hide these actions.
Signed iPhone and physical NDEF tag qualification remain pending.

## Paired listening history

Open Recent playback history and select Sync when a compatible paired device is
connected. This explicitly imports that peer's account-matching occurrences into
the current profile, in eight-event cursor pages. Repeat the operation from the
other device for a two-way merge. Original occurrence UUIDs are retained and
listened-time/finished fields merge monotonically, so replay does not add plays.
Imported history feeds local charts but never replays server scrobbles.

Newly recorded events carry a hashed portable server/account identity. Plex
requires a verified Plex account and Home-user identity; Jellyfin/Emby use the
server and user identity. Direct Plex connections without verified user identity
and old unscoped events remain local instead of being guessed into an account.
Profile/account changes invalidate in-flight pages. Conflicting IDs roll back the
whole page. The operation has bounded pages, message sizes and deadlines; retry
after an interruption safely merges again. Clearing history is local, not a
cross-device deletion command, and a later import can restore the peer's copies.

## Cast music output

On Android and iOS, use the Now Playing device action to select a Cast receiver.
The receiver prepares the current track paused and acknowledges a matching owner
token/media session before local playback is released. The existing music queue
remains authoritative for transport, duplicate tracks, repeat, shuffle and edits;
its occurrence is preserved during the output switch. Cancelling the Cast output
returns to the local device. Disconnect or another sender taking over instead
returns locally paused and never stops the foreign media.

Cast resolves receiver-accessible HTTP streams using the current server account;
downloaded files, prefetch paths and native request-header sources are not sent.
Local EQ, normalization and two-decoder fades are not applied to remote PCM and
are reported absent. Receiver playback beyond the current track requires the
sender process to remain active; receiver-side durable autonomous queues, live
codec qualification and Google Cast speaker-group management remain separate.
Paired synchronization is app-to-app, not a Cast speaker-group controller.
