# Connected games code completion

This ledger tracks the remaining original implementation scope on PR #81. It
does not replace the SDK build and real-device acceptance cases in
[LIVE_TEST_HANDOFF.md](LIVE_TEST_HANDOFF.md).

## Implemented in this follow-through

- Desktop/Apple receiver creation and teardown are owned by the workspace
  session. Presentation widgets can unmount/remount without restarting the
  transport. Detachment releases input and hides native planes. Late creation,
  timeout, reconnect and profile retirement still retire the correct receiver.
- Android retains its session outside the Flutter PlatformView. The video
  worker rebuilds its output against replacement Surfaces while preserving
  transport/audio ownership; engine destruction and explicit disconnect retire
  the session. Older view arguments keep their original disposal behavior.
- The authenticated internet tunnel carries opted-in Pyrowave/HDR requests.
  Native decoder/display probes and conventional-codec fallback remain
  authoritative. The tunnel forwards the same bounded encrypted datagrams,
  independent of codec; hardware and real-network throughput remain unmeasured.

## Work still in progress

- In-app per-game controller remapping and the existing Steam configuration path.
- Remote Play Together/host overlay and capture controls.
- Multi-computer LAN-install assistance and honest transfer state.
- Cloud settings: public Steamworks exposes account-wide read access and an
  app-scoped setter for the calling game's own AppID. A general account-wide
  mutation must not be fabricated from those APIs or from an assumed VDF key.
- Documentation reconciliation, security checks and focused regression coverage
  for the completed paths.

## Contract references

- [Valve Remote Play](https://partner.steamgames.com/doc/api/ISteamRemotePlay)
- [Valve Remote Storage](https://partner.steamgames.com/doc/api/ISteamRemoteStorage)
- [Valve Steam Input](https://partner.steamgames.com/doc/api/ISteamInput)
- [Valve LAN transfers](https://help.steampowered.com/en/faqs/view/46BD-6BA8-B012-CE43)

Game-side Steamworks methods do not authorize a third-party client to impersonate
another game's AppID. LAN file transfer selection and integrity remain Steam's
responsibility; installation assistance must report submission and observed
inventory separately from completion or a guaranteed transfer source.

## Evidence

- Nineteen targeted Flutter tests pass for presentation lifetime, late teardown,
  input ownership and the real TLS/UDP relay fixture after enabling codec
  preferences over the tunnel.
- Android Steam Java sources compile against API 36 (20 existing deprecation
  warnings). This does not establish a Kotlin/Gradle/NDK or device build.
