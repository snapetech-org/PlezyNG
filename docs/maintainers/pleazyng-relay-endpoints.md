# Pleazyng service endpoint inventory

This is the source-backed inventory of HTTP and WebSocket routes in the
self-hostable Pleazyng Go relay and the first-party MAL OAuth broker. The
operator's public API hostname now serves only the Cloudflare Worker; its home
Go service and Tunnel origin are disabled. Other routes below are available
only when a user operates a relay and explicitly configures it in the app.

The route list is taken from [`main.go`](../../server/main.go),
[`oauth.go`](../../server/oauth.go), and the registered handlers linked below. App callers
are taken from the corresponding Dart clients. Update this page whenever a
handler is mounted, an app callsite changes, or a route is retired.

## Service origins

| App setting or broker constant | Use |
| --- | --- |
| Settings → Services → User-hosted relay | Optional HTTPS base URL for a relay the user operates. Official builds leave it unset; relay-backed features fail closed until configured. |
| `pleazyngOAuthBrokerBaseUrl` | Fixed first-party OAuth handoff origin. It handles the MAL code-only flow and receives neither PKCE verifier nor provider tokens. |
| Profile music relay URL | Optional profile-specific URL for `/music/connect/relay`; if empty, the app uses the user-configured relay base URL. |

The Flutter URL validation and defaults live in [`plezy_server.dart`](../../lib/services/plezy_server.dart).
The app requires HTTPS and does not infer a relay from a build variable.

## HTTP and WebSocket routes

| Route | Method / transport | App or service use | Registration and availability |
| --- | --- | --- | --- |
| `/health` | `GET` HTTP | Self-hosted relay health check. | Always mounted in [`main.go`](../../server/main.go); not available on the operator's public API hostname. |
| `/relay` | `GET` WebSocket upgrade | Pleazyng room relay protocol. Client messages include `create`, `join`, `resume`, `broadcast`, `sendTo`, `ping`, `leave`, `endSession`, and `transferHost`; see [`relay_protocol.json`](../../relay_protocol.json). | Always mounted in [`main.go`](../../server/main.go) for user-hosted deployments. No current production Dart callsite to this Go route was found. |
| `/logs` | `POST` HTTP | Upload a redacted diagnostic log from **Settings → Logs** or the startup-failure screen. Returns an opaque ID. | Available only through a user-configured relay. The app caller is [`log_upload_service.dart`](../../lib/services/log_upload_service.dart). |
| `/logs/{id}` | `GET` HTTP | Retrieve a previously uploaded diagnostic log through its unguessable link. | Always mounted as `/logs/`. The ID is a read capability; responses are private and non-cacheable. Handler: [`main.go`](../../server/main.go). |
| `/posters` | `POST` HTTP | Upload a bounded image used as a Discord Rich Presence thumbnail. Returns an ID and relative poster URL. | Available only through a user-configured relay. Caller: [`discord_rpc_service.dart`](../../lib/services/discord_rpc_service.dart). |
| `/posters/{filename}` | `GET` HTTP | Fetch the uploaded thumbnail. Discord fetches the returned absolute URL. | Always mounted as `/posters/`; response caching lasts only until the upload expires. Handler: [`main.go`](../../server/main.go). |
| `/commerce/comic-link` | `POST` HTTP; `OPTIONS` preflight | Resolve an eligible book/comic/game storefront URL to an approved tracked destination; direct official URL remains the client fallback. | Available only through a user-configured relay; partner results depend on approval flags and credentials. Caller: [`comic_commerce_link_client.dart`](../../lib/services/comic_commerce_link_client.dart); handler: [`comic_commerce.go`](../../server/comic_commerce.go). |
| `/commerce/watchmode-availability` | `GET` HTTP with `tmdbType`, `tmdbId`, and `region`; `OPTIONS` preflight | Fetch title availability sources for a movie or TV title. | Available only through a user-configured relay; returns unavailable unless its operator supplies an approved key. Caller: [`watchmode_availability_client.dart`](../../lib/services/watchmode_availability_client.dart); handler: [`watchmode_availability.go`](../../server/watchmode_availability.go). |
| `/music/connect/relay` | `GET` WebSocket upgrade | Optional away-from-home **Music → Play on** receiver/controller connection. The relay routes encrypted music-control frames; the receiving app accesses its own media server. | Self-hosted only and mounted only when `MUSIC_CONNECT_RELAY_ENABLED=true`. Caller and URI construction: [`music_relay_configuration.dart`](../../lib/services/music/music_relay_configuration.dart); handler: [`music_connect_relay.go`](../../server/music_connect_relay.go). |
| `/games/steam/relay` | `GET` WebSocket upgrade | Optional paired Steam host/receiver internet stream and control tunnel. Steam UDP traffic may also use the separately configured `STEAM_STREAM_RELAY_UDP_PORT`. | Self-hosted only; mounted when `STEAM_STREAM_RELAY_ENABLED=true` and OAuth is configured. Client route: [`steam_internet_tunnel.dart`](../../lib/games/steam_internet_tunnel.dart); handler: [`steam_relay.go`](../../server/steam_relay.go). The operator-hosted service and public origin are disabled. |

`/relay` is the Go service's Pleazyng room protocol. The current Watch Together
feature instead constructs a `.../v1/ws` WebSocket URL through the Open Watch
Party SDK, using its public relays or a user-configured Open Watch Party relay;
that traffic does not use the user-hosted relay setting or this Go service's
`/relay` path. See [`watch_party_relays.dart`](../../lib/watch_together/services/watch_party_relays.dart).

## Shared request limits and abuse bans

The Go service applies an HTTP token bucket to each resolved client address:
120 requests of burst capacity, refilling at 30 requests per second. `/health`
is exempt for local liveness checks. Existing route-specific limits remain in
place. WebSocket handshakes share a per-address limit of five immediate
connections and then one per second. The anonymous `/relay` WebSocket keeps its
per-connection limit of 30 messages in a burst and 10 per second, plus a shared
per-address budget of 150 burst messages and 50 per second across `/relay` and
Music Connect. Steam's paired stream uses a shared per-address limit of 2,000
frames in a burst and 1,000 per second, alongside its existing 8 MiB per
second byte cap. Room lookups and room creation have additional per-address
quotas.

Shared service or room-capacity responses do not count as abuse signals; the
ban policy applies only to source-controlled throttles and the explicit relay
authentication/message violations above.

Repeated source-controlled rate-limit responses, invalid Steam/Music relay
credentials, or relay message-limit violations count toward one abuse record
across the service. Ten signals inside 15 minutes cause a 15-minute ban. A new
ban within 30 days escalates to one hour, then to a maximum of 24 hours. Active
bans apply across the API routes, including WebSocket messages; the liveness
route remains available. The service persists only keyed HMACs of normalized
source addresses and ban expiry/level data. Both the hash key and state file
must remain private in the service state directory. Source addresses and
strike windows are held only in bounded memory.

This is layered with Cloudflare's request-rate ceiling and the endpoint-level
quotas. The counters are IP-based: users behind the same NAT or IPv6 `/64`
share limits and can share a timed ban. The ban durations are finite; this is
not a permanent blocklist or a defense against a distributed flood.

## OAuth, Steam account, and session-capability routes

The Go service mounts user-hosted account paths in [`oauth.go`](../../server/oauth.go);
provider-specific behavior is implemented in the linked files. It returns
`503` when `OAUTH_BASE_URL` is unset. The first-party Worker handles a separate
MAL code-only flow. Official app builds do not select the Go relay by default;
users must configure a relay they operate in **Settings → Services**. The
endpoint contract and Worker routing are documented in the
[OAuth Worker runbook](../../server/cloudflare-oauth/README.md).

| Route | Method | App or browser use | Notes |
| --- | --- | --- | --- |
| `/auth/pkce/start` | `POST` | Start the MAL browser handoff and receive a short-lived URL and device poll capability. | First-party Worker only. The app adds its locally held plain PKCE verifier and opens MAL directly. |
| `/auth/result` | `GET` | Device polls for a one-time result. The first-party Worker requires its capability in `Authorization: Bearer …`; it rejects query-string capabilities. User-hosted Go relays retain their own legacy query contract. | Worker returns only the MAL authorization code/error. The user-hosted Go relay may return provider tokens or account capabilities. Long-poll; `204` means retry, `410` means expired/consumed. |
| `/auth/start` | `POST` | Begin Trakt browser, AniList, MAL, or Steam sign-in on a configured user-hosted relay. | First-party Worker returns `410` for retired MAL token exchange and `404` for other providers; it never forwards to the home origin. Trakt TV device-code auth goes directly to Trakt. Steam Cloud uses its dedicated `/auth/steam/cloud/start` route. |
| `/auth/done` | `GET` | Static OAuth completion page. | Self-hosted Go relay only; browser-facing and no account operation. |
| `/auth/{service}?state={state}` | `GET` | Browser authorization handoff for a provider on a user-hosted relay. | Go providers: `mal`, `trakt`, `anilist`, `steam`, and the dedicated `steam-cloud` flow. First-party MAL authorization URLs are built by the app and go directly to MAL. |
| `/auth/{service}/callback` | `GET` | Provider callback for a service on a user-hosted relay. | One-use state is checked by the provider handler. First-party `/auth/mal/callback` stores only a code for the app. Steam Cloud callback behavior is listed separately below. |
| `/auth/steam/library` | `POST`, `DELETE` | Refresh the linked Steam game catalog (`POST`) or revoke its catalog capability (`DELETE`). | Requires a bearer catalog capability; [`steam_catalog.go`](../../server/steam_catalog.go). |
| `/auth/steam/game` | `POST` | Read Steam game activity for the selected game, optionally including friends currently playing. | Uses the verified Steam identity in the bearer catalog capability; [`steam_game_context.go`](../../server/steam_game_context.go). |
| `/auth/steam/cloud/capabilities` | `POST` | Ask whether a selected Steam game has supported Steam Cloud read/write access. | Uses a bearer catalog capability; [`steam_cloud.go`](../../server/steam_cloud.go). |
| `/auth/steam/cloud/start` | `POST` | Start a consented Steam Cloud authorization for a selected game; returns a browser URL and temporary device poll capability. | The resulting browser URL is `/auth/steam-cloud?state=...`; [`steam_cloud.go`](../../server/steam_cloud.go). |
| `/auth/steam-cloud` | `GET` | Browser handoff to Steam for the Steam Cloud authorization started above. | State-bound and short-lived; [`oauth.go`](../../server/oauth.go), [`steam_cloud.go`](../../server/steam_cloud.go). |
| `/auth/steam-cloud/callback` | `GET`, `POST` | `GET` serves the callback page that reads Steam's fragment token; that page makes a same-origin `POST` to submit it. | The app does not receive Steam's upstream token. Handler: [`steam_cloud.go`](../../server/steam_cloud.go). |
| `/auth/steam/cloud/files` | `POST`, `DELETE` | With `POST`, list/download/upload/delete an authorized Steam Cloud file using JSON `action` values `list`, `download`, `upload`, or `delete`. `DELETE` retires the temporary Cloud capability. | File deletion is a JSON action over `POST`; HTTP `DELETE` revokes the grant. Requires a separate Steam Cloud capability. Handler: [`steam_cloud.go`](../../server/steam_cloud.go). |
| `/auth/steam/families` | `POST` | Query capabilities; start and poll authorization; read family state; review and commit an explicit change; or close the temporary session. | JSON `operation` values: `capabilities`, `start`, `poll`, `state`, `review`, `commit`, `close`. Uses a Steam catalog bearer plus a short-lived Families session after start; [`steam_families.go`](../../server/steam_families.go). |

The first-party Worker routes are `GET /auth/edge-health`, `POST
/auth/pkce/start`, `GET /auth/result` for its one-time code capability, and
`GET /auth/mal/callback`. The Worker never proxies to an origin. The home Go
service and its Tunnel connector are disabled; other Go routes require a relay
the user operates and configures. Official builds contain no default relay
URL.

## What a path-only regional restriction means

The operator's public hostname is not a general-purpose Go relay. It accepts
only the four Worker routes above; `GET /health`, `/relay`, logs, posters,
commerce, music and Steam routes return `404` there. These Go features operate
only on a relay the user hosts and explicitly configures. The region exception
exists for MAL's code-only OAuth start, poll and callback flow.

The app's post-sign-in Trakt API traffic goes directly to Trakt, not through
this relay. Similarly, Plex/Jellyfin/Emby server requests and provider APIs
that the client calls directly are outside this inventory. The inventory
describes requests to Pleazyng-owned ingress and does not claim that external
services are reachable or unaffected by their own regional controls.

## Route sources and maintenance

- Core route registration and log/poster handlers: [`main.go`](../../server/main.go).
- OAuth dispatch: [`oauth.go`](../../server/oauth.go); Steam catalog, game, Cloud, and Families handlers: [`steam_catalog.go`](../../server/steam_catalog.go), [`steam_game_context.go`](../../server/steam_game_context.go), [`steam_cloud.go`](../../server/steam_cloud.go), [`steam_families.go`](../../server/steam_families.go).
- Optional commerce handlers: [`comic_commerce.go`](../../server/comic_commerce.go) and [`watchmode_availability.go`](../../server/watchmode_availability.go).
- Optional WebSocket handlers: [`music_connect_relay.go`](../../server/music_connect_relay.go) and [`steam_relay.go`](../../server/steam_relay.go).
- Music Connect deployment and validation details: [`MUSIC_CONNECT.md`](../../server/MUSIC_CONNECT.md).
- App origin selection: [`plezy_server.dart`](../../lib/services/plezy_server.dart). App route callers are linked in the tables above.
- OAuth Worker's path dispatch: [`worker.mjs`](../../server/cloudflare-oauth/worker.mjs).

When adding a mounted route, record its method/transport, user-visible feature,
client caller, configuration gate, and whether it uses the `/auth/` subtree.
For WebSocket protocols, update their message or capability surface here as
well as the canonical protocol source.
