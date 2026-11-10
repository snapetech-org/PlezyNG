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
from their owning server before editing. The advanced query preserves repeated
parameters and nested groups; the filter form can add a grouped condition.
Preview queries the server; saving creates or updates the server's rule-based
playlist instead of freezing a local list. Sorting and limits are query rules.
Save-as creates a separate smart playlist. Backend permission failures remain
failures. Local finite download stations are a different feature.

## History and conflicting offline edits

Music history is device-local listening history, paged by occurrence rather than
deduplicated by track. New database writes refresh the view. This is not a server
history import or a RAM-independent live playback queue.

The music-home Sync action shows conflicting offline rating/favorite decisions.
Choose the reviewed local or remote value explicitly. A stale conflict revision
cannot overwrite a newer decision; an already-applied remote value clears its
pending edit without another write. Server APIs do not provide atomic
compare-and-set, so simultaneous changes between a read and write are not
claimed to be transactional.

## Paired synchronization

1. Configure and authorize both app instances normally, then pair them using the
   existing companion remote flow. Both must advertise music group version 1.
2. Start a music queue, then select **Sync: device name** in Now Playing.
3. The receiver validates its own library access and prepares the queue paused.
   Playback starts following only after clock sampling and source preparation.
4. Use the initiating device for group transport. Cancel Sync to leave.

This is a group of two app instances, distinct from **transfer**, which pauses
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
multi-room audio: decoder/DAC/acoustic latency is not calibrated. Arbitrary
multi-endpoint grouping and Plexamp protocol interoperability are not implemented.

## Android widget

Install the app internally, configure a profile and start music before adding
the home-screen music widget. Android widgets are not supported from adopted or
removable app storage. Transport uses the same queue/session as the app and
rejects intents from a previous profile or queue revision. No stream credentials
or durable track metadata are stored by the widget. If the process has no live
music session, tapping opens the app instead of silently restoring playback.

## Android NFC

On NFC-capable Android devices, open music details and select the NFC-writing
action. Hold a writable tag near the device until Saved appears, or cancel the
scan. Capacity, read-only tags, unsupported tags and the scan deadline can cause
a write to fail; success is shown only after the native write completes.

The NDEF record contains only a `pleazyng://play` link with server/item identity,
never a server token, media URL or account credentials. Scanning resolves that
identity against the currently authorized profile. A tag is not an access grant.
Tags are not permanently locked by the writer. Physical tag qualification and
other platforms' NFC writing remain separate work.

## Cast ownership limits

Existing Cast loads now wait for a matching ownership token and receiver media
session, reject changed source authentication/profile intent, and stop treating
another sender's media as owned progress or transport. This does not implement a
complete shared music Cast queue. Paired synchronization is an app-to-app feature,
not a Google Cast speaker-group controller.
