# Play on a Pleazyng device

Tap **Play on** in Now Playing or the mini-player. Choose this device or a
reachable paired player. The receiving app resumes the same track and queue,
streams from its authorized media server, and reports playback back to the
controller. Choose **This device** to bring the current session back.

## Implementation

- [ ] Surface one device picker across phone, desktop and TV. Reuse Companion
  Remote discovery and pairing, remember devices per profile, and show the
  active output, connecting state, unavailable targets and recovery actions.
  Keep pairing and moving playback separate. Provide a visible route back to
  local playback and accessible labels and TV focus order.
- [ ] Extend the profile-owned music session and paired protocol. Publish
  receiver-authoritative track, queue, playhead, transport and supported
  volume. Route ordinary Now Playing, mini-player and queue controls to the
  active receiver. Take playback back from the receiver's current state
  and move it to another paired device.
- [ ] Prepare and authorize the receiver before committing ownership. Match
  acknowledgements to a session revision, reconcile retries and lost replies,
  and preserve the current session when a move is rejected. Transfer large
  queues with bounded chunks and validate queue size, order and media identity.
  Keep server credentials, URLs and local files on their owning devices.
- [ ] Make pairing reusable for Plex accounts, direct Plex, Jellyfin and Emby,
  with explicit consent, per-profile trust and a way to forget a device.
  Advertise receiver availability only while the app can accept the handoff.
  Use the existing Linux endpoint for Pi and desktop background use and
  respect handheld and TV lifecycle limits.
- [ ] Add optional cross-network discovery and control through a linked-device
  relay. Use outbound authenticated connections and scoped device credentials.
  Preserve direct LAN connections and have each receiver stream from its own
  media server. Document the deployment and pairing path.
- [ ] Add regression coverage for pairing, discovery, long and duplicate
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
