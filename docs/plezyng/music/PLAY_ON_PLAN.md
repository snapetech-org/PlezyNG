# Play on a Pleazyng device

Tap **Play on** in Now Playing or the mini-player. Choose this device or a
reachable paired player. The receiving app resumes the same track and queue,
streams from its authorized media server, and reports playback back to the
controller. Choose **This device** to bring the current session back.

## Player entry points, 2026-11-12

Playback moves only when the user selects an output from an open player. The
receiver plays from the current position and both devices can control the
session. Preserve a pause when moving an open session. Keep the regular Play
and Resume actions for starting playback after browsing or opening the app.

- [x] Keep saved Multiview sessions accessible from Settings and open the
  recovery tray only on request.
- [x] Put the music output chooser on the player and mini-player. Keep setup
  available in Settings.
- [ ] Move video output selection into the active player. Keep the sender's
  controls connected to the receiving session after the move.

## Implementation

- [x] Surface one device picker across phone, desktop and TV. Reuse Companion
  Remote discovery and pairing, remember devices per profile, and show the
  active output, connecting state, unavailable targets and recovery actions.
  Keep pairing and moving playback separate. Provide a visible route back to
  local playback and accessible labels and TV focus order.
- [x] Extend the profile-owned music session and paired protocol. Publish
  receiver-authoritative track, queue, playhead, transport and supported
  volume. Route ordinary Now Playing, mini-player and queue controls to the
  active receiver. Take playback back from the receiver's current state
  and move it to another paired device.
- [x] Prepare and authorize the receiver before committing ownership. Match
  acknowledgements to a session revision, reconcile retries and lost replies,
  and preserve the current session when a move is rejected. Transfer large
  queues with bounded chunks and validate queue size, order and media identity.
  Keep server credentials, URLs and local files on their owning devices.
- [x] Make pairing reusable for Plex accounts, direct Plex, Jellyfin and Emby,
  with explicit consent, per-profile trust and a way to forget a device.
  Advertise receiver availability only while the app can accept the handoff.
  Use the existing Linux endpoint for Pi and desktop background use and
  respect handheld and TV lifecycle limits.
- [x] Add optional cross-network discovery and control through a linked-device
  relay. Use outbound authenticated connections and scoped device credentials.
  Preserve direct LAN connections and have each receiver stream from its own
  media server. Document the deployment and pairing path.
- [x] Add regression coverage for pairing, discovery, long and duplicate
  queues, remote controls, switching twice, return to device, revocation,
  simultaneous requests, timeouts and reconnect. Record software checks
  separately from physical phone, TV and Pi results.

## Release checks

Run the focused music, companion and UI suites. Exercise phone → TV →
desktop → phone with both paused and active playback. Confirm the receiver
keeps playing after the controller disconnects, a failed move leaves the
current output playing, and taking over from another controller uses the
latest position and queue. Check a direct LAN pairing and an away-from-home
pairing with the receiver able to reach its media server. Qualify each
supported receiver on the hardware and app lifecycle it advertises.

Related work is tracked in the [music status](STATUS.md) and
[Companion Remote pairing guide](PAIRING_AND_SHORTCUTS.md).

## Checkpoint, 2026-11-11

The six implementation packages are committed to main. The picker covers
Music home, Now Playing and the mini-player, with receiver setup and optional
away-from-home controls. Receiver-owned playback, controls, transactional
handoff/return, large queues, encrypted invitations, LAN/relay fallback and
active-controller reconnect are integrated. The relay has bounded admission,
queues and E2E paired music channels.

The final hosted run at `dedb73b` passed two focused encrypted-loopback
preflight checks and all 546 tests in the integrated music, Companion,
receiver, WebSocket, screen and widget suite. This includes real session
handoff/control/return/disconnect, WSS relay reconnect, interrupted commits,
capability delivery during authentication, receiver revocation and the
320-pixel picker at 200% text size. The preflight checks also run within the
full suite.

The complete Go server suite passed with `go test -race ./...`. Maintained
Dart formatting, full-lib analysis with the music/transport tests, localization
source hashes and placeholders, workflow action pins/security and diff checks
also passed. New translations are machine-authored and await native-language
review.

The hosted run and its exact source checkpoint are available in
[Music device handoff, run 42932674878](https://github.com/snapetech-org/pleazyng/actions/runs/42932674878).

Production relay activation, distribution in an app release, physical-device
qualification and native-language review remain external acceptance work. Software implementation checkboxes
above track delivered code. Follow [the user guide](PLAY_ON.md) and
[relay deployment guide](../../../server/MUSIC_CONNECT.md).
