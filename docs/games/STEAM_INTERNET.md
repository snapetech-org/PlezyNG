# Paired Steam internet streaming

PR #81 implements an opt-in PlezyNG packet tunnel with an encrypted WebSocket
relay, automatic public-IPv4 UDP hole punching and relay fallback. It carries
the existing native Steam transport; it is not Valve Steam Datagram Relay and
does not confer access to Valve's private client services.

The implementation passes local TLS/UDP integration and authorization tests.
Real routers, mobile networks, sustained throughput and platform packages still
need qualification. See [VALIDATION.md](VALIDATION.md) and
[LIVE_TEST_HANDOFF.md](LIVE_TEST_HANDOFF.md).

## Existing app flow

1. On the gaming computer, run Steam and PlezyNG's Companion Remote server.
   Link Steam in PlezyNG. The host relay listener runs on Windows, macOS and
   Linux, in the active Companion profile only.
2. On the receiving device, link the **same Steam account**. Pair both Steam
   and Companion on the LAN and import the computer's installed games once.
   The existing inventory stores the association between the Steam host and
   Companion peer. Repeat for each computer; the unified AppID card retains
   its separate computer routes.
3. Enable **Internet streaming** in Games settings on both devices. This
   profile preference defaults off. The control appears only in a build
   configured for an approved relay origin. Existing theme, settings controls,
   text scaling, rounded icons and translations/fallbacks apply.
4. Play the existing game card and select its computer as usual. A bounded
   unicast discovery probe prefers the LAN route. If that host is unreachable,
   the paired tunnel supplies temporary loopback ports to the native receiver.
   The saved host ID, Steam pairing and preferred route are unchanged.
5. The existing stream diagnostics identify **Direct encrypted connection** or
   **Encrypted relay**. UDP is preferred after an authenticated round trip;
   a lost direct path returns to the relay after its 2.5-second lease expires.
   Reconnect creates new keys and re-evaluates the LAN/internet route.

Internet sessions preserve the chosen codec/Pyrowave/HDR preferences. Native
decoder/display qualification and conventional fallback remain authoritative. The internet tunnel neither wakes a sleeping computer
nor runs when its Companion server is stopped. Steam's own launch acceptance,
pairing, game availability and session encryption are still required.

## Operator setup

Use the same server process and HTTPS public origin as Steam OpenID/catalog
admission. Configure the existing Steam catalog service first. Set the server
options in [steam-relay.env.example](../../server/steam-relay.env.example):

```dotenv
STEAM_STREAM_RELAY_ENABLED=true
# Explicitly provision capacity before increasing this bound (1..64 MiB/s).
STEAM_STREAM_RELAY_MIB_PER_SECOND=8
# Optional: a public IPv4 UDP observation port, identical inside/outside Docker.
STEAM_STREAM_RELAY_UDP_PORT=3479
```

Build the app with matching origins:

```sh
--dart-define=PLEZY_SERVER_BASE_URL=https://your-approved-server.example
--dart-define=PLEZY_STEAM_RELAY_URL=https://your-approved-server.example
```

The client rejects HTTP, user-info, query/fragment credentials and an origin
different from its catalog server. The relay refuses initialization without
Steam admission or a configured HTTPS public origin. TLS termination belongs
to the existing reverse proxy; forward WebSocket upgrades at
`/games/steam/relay`, retain the admission headers, and use an idle timeout
greater than 45 seconds. Never log Authorization or X-Steam-Relay-Admission.
Do not expose the plaintext application listener publicly.

Startup now rejects explicitly requested but unavailable Steam services before
opening the HTTP listener. Invalid enabled flags, incomplete Cloud configuration,
an unusable HTTPS origin, invalid relay bandwidth/UDP settings or an occupied
requested UDP port cause a nonzero exit with a fixed, credential-free diagnostic.
Unset/false optional features preserve the existing deployment behavior. This
prevents `/health` from looking healthy while a requested Steam route is absent;
health still does not establish public TLS, Valve grants or real NAT traversal.
Correct the configuration before restarting rather than disabling the feature
to make a deployment check appear successful.

WSS works without a UDP port. For automatic direct traversal, expose the
configured UDP port on the **same public IPv4 hostname**. The optional
[Compose override](../../server/steam-relay.compose.yml) publishes it. A CDN or
reverse proxy that does not forward that UDP port prevents direct upgrading;
WSS continues to work. No UPnP, router configuration or automatic port mapping
is performed on either user's network. IPv6-only networks and restrictive or
symmetric NATs can use WSS when the server is reachable.

Room membership and catalog grants are in memory. Use one process, or implement
shared admission/room routing before horizontally distributing this service.
A restart invalidates grants and sessions; link again if admission has expired.
The server caps rooms at eight, rooms per Steam account at four and connections
per source IP at eight. Provision and monitor bandwidth before enabling it;
these are implementation limits, not a public service capacity commitment.

## Trust and resource boundaries

- Both endpoints need a valid catalog bearer on this server and the same
  verified SteamID. This is admission only; it does not replace Steam pairing
  or imply game ownership. A separate opaque pairing-derived capability names
  the room. Neither credential appears in a URL.
- A paired Companion context authenticates fresh X25519 public keys and random
  nonces with HMAC-SHA256. HKDF derives separate directional AES-256-GCM keys.
  Message kind and sequence are authenticated. A 2,048-packet replay window
  allows bounded UDP reordering; bad tags cannot advance it. Pairing material
  and plaintext Steam packets are not sent to the relay.
- UDP observation accepts only an exact 36-byte cookie probe from a public
  IPv4 source. It sends **no UDP response**. It reports the observed address
  over that cookie's authenticated WSS connection. Peers exchange candidates
  inside the encrypted channel. The direct route requires an encrypted
  challenge/response before carrying game traffic.
- Only six Steam UDP channels, 27031–27036, can be forwarded. On the host they
  target `127.0.0.1`; there is no arbitrary host/port forwarding. Native adapters
  accept an all-or-nothing set of distinct loopback ports and reject an
  out-of-range Steam launch port. Older native adapters keep their LAN path.
- The relay accepts two endpoints per room, binary messages no larger than
  64 KiB, 16 queued frames per endpoint, a default 8 MiB/s and 32 GiB per direction over a
  two-hour connection. Deadlines bound slow readers and idle sockets. The
  client limits datagrams to 2,048 bytes, batches to 128 datagrams/60 KiB, and
  input/output queues to 32 frames. Congestion drops data or closes an
  overloaded control channel rather than growing memory without a bound.
- Disabling the profile permission, stopping Companion, rotating pairing,
  changing profile or retiring the workspace session/native playback closes the
  owned route. The server checks catalog admission on each incoming message
  and every 15 seconds while idle/direct; revoked admission closes the room.
  These are explicit revocation bounds, not instantaneous remote revocation.
- The relay operator can see admission identity, IP addresses, timing and byte
  counts. Paired devices learn each other's public IPv4 candidate. The settings
  copy discloses network-address sharing and potentially substantial data use.

The protocol has local regression coverage, not an independent cryptographic
audit. Hardware-backed zeroization of Dart-managed key bytes is not guaranteed.

## Live qualification

Use two authorized devices, a disposable game session, and the exact PR head.

1. Confirm defaults produce no relay activity. Enable both devices; verify LAN
   still uses the original host route and old builds without `internetTunnel`
   continue working on LAN. Test different Steam accounts, absent/expired
   admission, wrong/rotated Companion pairing and a stopped host server.
2. Test one card with routes on the Steambox, desktop and BC250. On another
   network, select each route explicitly. Confirm only the selected computer
   launches and an unrelated computer cannot join its room.
3. Test separate home NATs, mobile CGNAT, UDP-blocked Wi-Fi and IPv6-only access.
   Observe relay start, successful direct upgrade where possible, then block
   UDP during playback and measure fallback interruption. Also interrupt WSS:
   direct-only playback must stop when relay admission is lost.
4. Revoke pairing, unlink Steam, disable the permission and change profiles
   during connection and playback. Close/reconnect/resize the retained pane;
   verify released input, no old socket or keys reused, and current route labels.
5. Measure H.264 and HEVC at the existing presets, loss/reordering, relay latency,
   memory, CPU, thermals and metered usage over a sustained session. Test a
   two-hour limit and a full/slow relay. Record failures separately from
   deployment and unsupported-NAT fallback.
6. Verify keyboard, controller, screen-reader and large-text access to the
   setting and diagnostics. New locale entries are English fallbacks awaiting
   language review.

The automated fixture uses real localhost TLS, WSS and UDP sockets, authentic
codec handshakes, fake Steam loopback datagrams and two UDP proxies. It proves
packet delivery, encryption, upgrade, loss fallback and permission retirement
under controlled conditions; it does not qualify a real Steam host or router.

The server advertises its per-direction byte rate in the optional version-one
`ready.bytesPerSecond` field. Receivers accept only 1..64 MiB/s, use 8 MiB/s for
older servers, and reserve 25% for protocol overhead and bursts when requesting
video bitrate. This ceiling also applies while using direct UDP so a later WSS
fallback does not immediately exceed the relay budget. It is a requested target,
not a throughput guarantee; Pyrowave and high-resolution streams still need
adequate provisioned bandwidth and real-network qualification. Geometry and
compressed-frame limits remain bounded independently of the relay packet size.
Presentation detachment preserves the tunnel; owner retirement closes it.
