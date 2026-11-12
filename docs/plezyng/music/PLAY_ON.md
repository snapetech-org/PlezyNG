# Play music on another device

Open **Play on** from Now Playing or the mini-player while a music session is
open. The speaker button shows the selected output in its accessible label.

## Pair and play

1. Open Pleazyng on the receiving phone, computer, TV or Linux endpoint.
   Configure its media-server connection and select the intended profile.
2. Open **Settings → Allow playback on this device → Companion Remote**,
   start the receiving server, and display its pairing code.
3. On the controlling device, open **Play on**, select the nearby player, and
   enter that code once. Manual host-and-port entry is also available.
4. Select the player to move the current music session. The receiver checks its
   own access, then takes over the queue and playhead. A rejected preparation
   leaves the source playing.
5. Use the player controls, queue editor and volume control on either device.
   Choose **This device** to bring the receiver's current session back, or
   select another player to move it again.

Receivers keep playing after a controller closes or disconnects. Keep the
receiving app running and its media server reachable.
The Linux endpoint package provides an unattended receiver after normal
profile setup.

Devices are remembered per profile. **Forget device** removes the controller's
saved connection and pairing. On the receiver, resetting its pairing code
revokes previous pairing capabilities and rotates its relay room. Pair again
after a reset.

## Away from home

1. On the receiver, expand **Settings → Allow playback on this device → Away from home**.
2. Use the configured music relay address or enter your deployment's HTTPS
   address, then enable **Away from home**.
3. Pair and select the receiver once on the same network so the controller can
   learn its encrypted relay invitation.
4. Later, select that remembered receiver from another network. Pleazyng uses
   an available direct connection or the saved relay invitation.

Official builds can supply the relay address through
`PLEAZYNG_RELAY_BASE_URL`. A service operator must enable and deploy the music
relay route. The [deployment guide](../../../server/MUSIC_CONNECT.md) covers
configuration and capacity. Self-hosted users can enter their own HTTPS relay.

The relay receives network addresses, connection timing and pairing-handshake
device identifiers, names, platforms and user identifiers. Queue metadata and
music commands are encrypted between paired devices. Each receiver streams
audio from its own authorized server. Pairing capabilities and relay
invitations are encrypted in the local credential vault.

Control reconnects automatically while the controller is active. Reconnection
reads the receiver's current session. A lost commit reply keeps the source
paused while the controller reconciles the target, preventing a second
automatic playback start. The picker reports an uncertain move and shows
reconnection status.

## Compatibility and limits

| Area | Behavior |
| --- | --- |
| Media connections | Plex accounts, direct Plex, Jellyfin and Emby use their profile-owned pairing identities and receiver authorization |
| Modern Pleazyng handoff | Up to 4,096 queue occurrences and 4 MiB per serialized message, including duplicate tracks, cursor, repeat and shuffle |
| Older paired builds | Existing version-1 transfer remains available with its 128-entry bound |
| Remembered devices | 32 most recently used players per profile |
| Discovery | Nearby discovery uses the local network, remembered relay invitations allow cross-network control |
| Cast | The same picker offers supported Cast receivers, with Cast's existing playback and queue limits |
| Phone and TV receiving | Availability follows the running app and platform lifecycle |
| Synchronized groups | The separate Sync controls manage simultaneous playback and retain their own protocol limits |
| Local effects | The receiving player applies its own audio settings |

A receiver must be able to resolve every transferred server identity. A local
file, missing server, revoked profile, inaccessible source, unsupported output
or oversized queue can reject a move. Screen-reader labels, keyboard/TV focus
and the route back to this device share the normal player surfaces.

## Validation record

At source checkpoint `dedb73b`, hosted Flutter checks passed all 546 integrated
tests plus two focused preflight checks. Coverage includes paired protocol
compatibility, handoff, control routing, queue framing, pairing, provider
integration and player screens. Regressions exercise encrypted loopback
transport, TLS WebSocket routing, replay rejection, reconnect, interrupted
commits and small-screen/large-text picker layouts. The complete Go server
suite passed with the race detector.

Physical phone, TV, Pi, sleep/wake, background receiving and real audio
continuity checks remain device qualification work. New labels require
native-language review. See [the implementation plan](PLAY_ON_PLAN.md) for
the current checkpoint and acceptance record.

