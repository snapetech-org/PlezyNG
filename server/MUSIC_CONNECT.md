# Music Connect relay deployment

The music relay is part of the existing Go service. It routes authenticated
WebSocket connections at `/music/connect/relay`. Both receiver and controller
connect outbound. Each receiving app owns its media-server access and music
session.

## Enable the route

Set the following environment variable in the relay deployment.

```dotenv
MUSIC_CONNECT_RELAY_ENABLED=true
```

The compose file already passes this variable to the service. Rebuild the
current source and recreate the relay container using the deployment's
existing public URL and trusted-proxy settings.

```sh
cd server
docker compose up -d --build relay
```

Expose the route through a publicly trusted HTTPS reverse proxy with WebSocket
upgrade support. Preserve the authorization and `X-Pleazyng-Music-*` headers.
Use a read timeout above 75 seconds so heartbeat traffic can keep the tunnel
alive. Disable caching for this path and redact authorization, capability and
room headers from request logs.

A simple unauthenticated health probe to the enabled route receives HTTP 401.
The service's existing health endpoint remains the container readiness check.

Official builds include no music-relay endpoint. Configure a user-operated
HTTPS base URL in **Settings → Services → User-hosted relay**; the app appends
`/music/connect/relay`. A profile may override that base in the relay picker.

## User activation

On a receiving device, open **Music → Play on → Away from home** and enable the
option. This starts the opted-in Companion receiver when needed. Keep the app
running. Pair once from the controlling device on the same network, then select
the receiver so its relay invitation is saved. Later selections can reconnect
through the relay from another network.

Resetting the receiver's pairing code closes existing receiver routes and
derives new host and controller capabilities. Previously saved invitations
then require renewed pairing. Disabling away-from-home closes the outbound
music relay presence.

## Protocol and limits

Host registration proves a random 256-bit host capability. Its SHA-256 digest
selects the room. Controllers use a separate capability learned through the
paired encrypted channel. Requests carry capabilities in headers. Receiver
and controller complete a fresh, pairing-derived challenge and AES-GCM channel
before music commands are accepted.

The relay sees handshake metadata and network addresses. Subsequent queue and
control frames are end-to-end encrypted. The app exposes the bounded music RPC
endpoint through this tunnel. The media stream goes from the receiver's own
server to that receiver.

| Per-process bound | Value |
| --- | --- |
| Receiver rooms | 128 |
| Total receiver/controller sockets | 256 |
| Sockets from one resolved source IP | 16 |
| Controllers in one room | 8 |
| WebSocket message | 64 KiB |
| Aggregate queued payload | 16 MiB |
| Per-socket bandwidth | 8 MiB burst, replenished at 1 MiB/s |
| Unauthenticated app-side E2E handshake | 10 seconds |
| App-side send and receive queues | 8 MiB each per encrypted controller link |

Rooms live in memory. Route every connection for one room to the same instance
when scaling. An upstream hash of `X-Pleazyng-Music-Room` can provide affinity
for this path. Capacity planning must account for the per-IP admission bound
on shared NATs. Receiver reconnects recreate rooms after process recovery.
Controllers reconcile receiver state after reconnecting.

The music route uses the existing trusted-proxy resolver. Configure exact
proxy CIDRs so forwarded source addresses reflect the intended client.
Admission budgets, queue bounds, deadlines and per-room limits remain enforced
by each service instance.

## Verification

Run the server suite from this checkout.

```sh
cd server
go test -race ./...
```

The focused GitHub workflow runs the Flutter music, Companion, picker and
WebSocket regressions. The TLS loopback test covers real receiver and
controller WebSocket clients, encrypted multi-frame requests and a second
controller connection after disconnect.

After deployment, verify a paired phone can select the receiver over cellular
data, control the queue, disconnect while playback continues, reconnect to the
current receiver state, and return playback locally. Record the receiver
platform and lifecycle state with the result.

