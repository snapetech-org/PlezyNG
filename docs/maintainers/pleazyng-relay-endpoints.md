# Pleazyng service endpoint inventory

This is the source-backed inventory of HTTP and WebSocket routes exposed by
the Pleazyng Go relay and the related app-facing OAuth routes. It maps each
route to the Pleazyng feature that calls it, names conditional routes, and
separates this service from external relays and provider APIs.

The route list is taken from [`main.go`](../../server/main.go),
[`oauth.go`](../../server/oauth.go), and the registered handlers linked below. App callers
are taken from the corresponding Dart clients. Update this page whenever a
handler is mounted, an app callsite changes, or a route is retired.

## Service origins

| Build or runtime setting | Use |
| --- | --- |
| `PLEAZYNG_RELAY_BASE_URL` | Default base URL for the owned relay. App code appends its route path. |
| `PLEAZYNG_COMIC_COMMERCE_BASE_URL` | Optional separate base for `/commerce/comic-link`; falls back to `PLEAZYNG_RELAY_BASE_URL`. |
| `PLEAZYNG_WATCHMODE_AVAILABILITY_BASE_URL` | Optional separate base for `/commerce/watchmode-availability`; falls back to `PLEAZYNG_RELAY_BASE_URL`. |
| `PLEZY_STEAM_RELAY_URL` | Optional same-origin base/path used to form the Steam WebSocket route. It must have the same HTTPS origin as `PLEAZYNG_RELAY_BASE_URL`. |
| User music relay URL | The profile's configured URL, defaulting to `PLEAZYNG_RELAY_BASE_URL`; the app appends `/music/connect/relay`. |

The Flutter base URL validation lives in [`plezy_server.dart`](../../lib/services/plezy_server.dart).
These settings identify service origins; they do not enumerate the paths
appended by individual feature clients.

## HTTP and WebSocket routes

| Route | Method / transport | App or service use | Registration and availability |
| --- | --- | --- | --- |
| `/health` | `GET` HTTP | Container and deployment health check. | Always mounted in [`main.go`](../../server/main.go). |
| `/relay` | `GET` WebSocket upgrade | Pleazyng room relay protocol. Client messages include `create`, `join`, `resume`, `broadcast`, `sendTo`, `ping`, `leave`, `endSession`, and `transferHost`; see [`relay_protocol.json`](../../relay_protocol.json). | Always mounted in [`main.go`](../../server/main.go). No current production Dart callsite to this Go route was found. The Watch Together app uses the separate Open Watch Party endpoint described below. |
| `/logs` | `POST` HTTP | Upload a redacted diagnostic log from **Settings → Logs** or the startup-failure screen. Returns an opaque ID. | Always mounted. The app caller is [`log_upload_service.dart`](../../lib/services/log_upload_service.dart). |
| `/logs/{id}` | `GET` HTTP | Retrieve a previously uploaded diagnostic log through its unguessable link. | Always mounted as `/logs/`. The ID is a read capability; responses are private and non-cacheable. Handler: [`main.go`](../../server/main.go). |
| `/posters` | `POST` HTTP | Upload a bounded image used as a Discord Rich Presence thumbnail. Returns an ID and relative poster URL. | Always mounted. Caller: [`discord_rpc_service.dart`](../../lib/services/discord_rpc_service.dart). |
| `/posters/{filename}` | `GET` HTTP | Fetch the uploaded thumbnail. Discord fetches the returned absolute URL. | Always mounted as `/posters/`; response caching lasts only until the upload expires. Handler: [`main.go`](../../server/main.go). |
| `/commerce/comic-link` | `POST` HTTP; `OPTIONS` preflight | Resolve an eligible book/comic/game storefront URL to an approved tracked destination; direct official URL remains the client fallback. | Always mounted; partner results depend on approval flags and credentials. Caller: [`comic_commerce_link_client.dart`](../../lib/services/comic_commerce_link_client.dart); handler: [`comic_commerce.go`](../../server/comic_commerce.go). |
| `/commerce/watchmode-availability` | `GET` HTTP with `tmdbType`, `tmdbId`, and `region`; `OPTIONS` preflight | Fetch title availability sources for a movie or TV title. | Always mounted, but returns unavailable unless the key and commercial-approval setting are configured. Caller: [`watchmode_availability_client.dart`](../../lib/services/watchmode_availability_client.dart); handler: [`watchmode_availability.go`](../../server/watchmode_availability.go). |
| `/music/connect/relay` | `GET` WebSocket upgrade | Optional away-from-home **Music → Play on** receiver/controller connection. The relay routes encrypted music-control frames; the receiving app accesses its own media server. | Mounted only when `MUSIC_CONNECT_RELAY_ENABLED=true`. Caller and URI construction: [`music_relay_configuration.dart`](../../lib/services/music/music_relay_configuration.dart); handler: [`music_connect_relay.go`](../../server/music_connect_relay.go). |
| `/games/steam/relay` | `GET` WebSocket upgrade | Optional paired Steam host/receiver internet stream and control tunnel. Steam UDP traffic may also use the separately configured `STEAM_STREAM_RELAY_UDP_PORT`. | Mounted only when `STEAM_STREAM_RELAY_ENABLED=true` and OAuth is configured. Client route: [`steam_internet_tunnel.dart`](../../lib/games/steam_internet_tunnel.dart); handler: [`steam_relay.go`](../../server/steam_relay.go). |

`/relay` is the Go service's Pleazyng room protocol. The current Watch Together
feature instead constructs a `.../v1/ws` WebSocket URL through the Open Watch
Party SDK, using its public relays or a user-configured Open Watch Party relay;
that traffic does not use `PLEAZYNG_RELAY_BASE_URL` or this Go service's
`/relay` path. See [`watch_party_relays.dart`](../../lib/watch_together/services/watch_party_relays.dart).

## OAuth, Steam account, and session-capability routes

All following routes use the `/auth/` prefix. The Go service mounts them in
[`oauth.go`](../../server/oauth.go); provider-specific behavior is implemented in the
linked files. If `OAUTH_BASE_URL` is unset, the Go `/auth/*` handler returns
`503`. A public OAuth Worker may serve the same app-facing paths for
MyAnimeList and AniList. The endpoint contract is the path and method shown
here; routing and deployment ownership are in the existing
[OAuth Worker runbook](../../server/cloudflare-oauth/README.md).

| Route | Method | App or browser use | Notes |
| --- | --- | --- | --- |
| `/auth/start` | `POST` | Begin Trakt, MyAnimeList, AniList, or Steam sign-in; returns a short-lived browser URL and device poll capability. | Worker-backed MyAnimeList/AniList and origin-backed local providers share this app-facing path. Steam Cloud uses its dedicated `/auth/steam/cloud/start` route. |
| `/auth/result?session={capability}` | `GET` | Device polls for the one-time sign-in result, including tracker tokens or Steam session capabilities. | Long-poll; `204` means retry, `410` means expired/consumed. |
| `/auth/done` | `GET` | Static OAuth completion page. | Browser-facing; no account operation. |
| `/auth/{service}?state={state}` | `GET` | Browser authorization handoff for a configured provider. | Go providers: `mal`, `trakt`, `anilist`, `steam`, and the dedicated `steam-cloud` flow. The Worker handles the MyAnimeList/AniList browser paths when those edge sessions are in use. |
| `/auth/{service}/callback` | `GET` | Provider callback for MyAnimeList, Trakt, AniList, and Steam OpenID. | One-use state is checked by the provider handler. Steam Cloud callback behavior is listed separately below. |
| `/auth/steam/library` | `POST`, `DELETE` | Refresh the linked Steam game catalog (`POST`) or revoke its catalog capability (`DELETE`). | Requires a bearer catalog capability; [`steam_catalog.go`](../../server/steam_catalog.go). |
| `/auth/steam/game` | `POST` | Read Steam game activity for the selected game, optionally including friends currently playing. | Uses the verified Steam identity in the bearer catalog capability; [`steam_game_context.go`](../../server/steam_game_context.go). |
| `/auth/steam/cloud/capabilities` | `POST` | Ask whether a selected Steam game has supported Steam Cloud read/write access. | Uses a bearer catalog capability; [`steam_cloud.go`](../../server/steam_cloud.go). |
| `/auth/steam/cloud/start` | `POST` | Start a consented Steam Cloud authorization for a selected game; returns a browser URL and temporary device poll capability. | The resulting browser URL is `/auth/steam-cloud?state=...`; [`steam_cloud.go`](../../server/steam_cloud.go). |
| `/auth/steam-cloud` | `GET` | Browser handoff to Steam for the Steam Cloud authorization started above. | State-bound and short-lived; [`oauth.go`](../../server/oauth.go), [`steam_cloud.go`](../../server/steam_cloud.go). |
| `/auth/steam-cloud/callback` | `GET`, `POST` | `GET` serves the callback page that reads Steam's fragment token; that page makes a same-origin `POST` to submit it. | The app does not receive Steam's upstream token. Handler: [`steam_cloud.go`](../../server/steam_cloud.go). |
| `/auth/steam/cloud/files` | `POST`, `DELETE` | With `POST`, list/download/upload/delete an authorized Steam Cloud file using JSON `action` values `list`, `download`, `upload`, or `delete`. `DELETE` retires the temporary Cloud capability. | File deletion is a JSON action over `POST`; HTTP `DELETE` revokes the grant. Requires a separate Steam Cloud capability. Handler: [`steam_cloud.go`](../../server/steam_cloud.go). |
| `/auth/steam/families` | `POST` | Query capabilities; start and poll authorization; read family state; review and commit an explicit change; or close the temporary session. | JSON `operation` values: `capabilities`, `start`, `poll`, `state`, `review`, `commit`, `close`. Uses a Steam catalog bearer plus a short-lived Families session after start; [`steam_families.go`](../../server/steam_families.go). |

The edge-only `GET /auth/edge-health` is an operational health probe, not an
app feature endpoint. Worker app routes are `POST /auth/start`,
`GET /auth/result`, and `GET /auth/{mal|anilist}` plus their corresponding
`/callback` paths. For other providers and Steam subroutes, the application
uses the same `/auth/*` URL family and the local handler contract above.

## What a path-only regional restriction means

If a public access rule allows only `/auth/*` on the configured relay origin,
then every non-`/auth/` route above is unreachable through that origin from the
affected region. That includes diagnostic uploads and poster reads, commerce
lookups, the room protocol, away-from-home music, and the Steam internet
streaming tunnel. In the allowed `/auth/*` subtree, impact is narrower than
OAuth alone: Steam catalog refresh, game activity, Steam Cloud capability/file
operations, and Steam Families session-capability calls also use it.

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
