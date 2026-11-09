# Owned provider registration handoff

Checked 2026-11-06. The owned relay is live at `https://pleazyng-api.snape.tech` and its core HTTPS/WSS checks pass. This does not establish any tracker registration, provider consent, commercial permission or end-to-end account synchronization. Optional clients remain unset until their own registrations and tests pass. Do not borrow upstream application IDs.

## Registration values

Use the application name **Pleazyng**, publisher **SnapeTech / SNAPE TECHNOLOGIES LIMITED**, the existing public source repository `https://github.com/snapetech-org/pleazyng`, and support/privacy pages under `https://snape.tech/privacy/pleazyng/`. Repository renaming is deferred. Keep owner authentication and client secrets outside this document and Git.

| Provider | Actual application path | Required registration/configuration | Current gate |
| --- | --- | --- | --- |
| Discord | Desktop Rich Presence | Own application and icon; asset keys matching the client; public `PLEAZYNG_DISCORD_APPLICATION_ID` | Own application `1568149865551237160` created; icon, description, privacy URL and optional `pleazyng` art asset saved. Repository variable staged; client compile activation and desktop runtime verification pending. Existing unrelated apps preserved |
| MyAnimeList | Relay authorization with PKCE; device performs public-client refresh | Exact callback `https://pleazyng-api.snape.tech/auth/mal/callback`; same owned public client ID in server `MAL_CLIENT_ID` and client `PLEAZYNG_MAL_CLIENT_ID` | Owner submitted signup; registration email verification and login pending. No API client created |
| AniList | Relay authorization-code exchange | Exact callback `https://pleazyng-api.snape.tech/auth/anilist/callback`; server-only `ANILIST_CLIENT_ID` and `ANILIST_CLIENT_SECRET`; no secret in app | Own login/client not verified; commercial terms below and actual consent/exchange tests required |
| Trakt | TV Device Code; browser S256 PKCE through owned relay | Same approved public Client ID in server `TRAKT_CLIENT_ID` and app `PLEAZYNG_TRAKT_CLIENT_ID`; no client secret; production HTTPS callback derived from relay base URL | Owned development app created; production approval and deployment/activation are separate gates. Follow [Trakt readiness](trakt-production-readiness.md) |
| Simkl | Native AUTH V2 device flow | Own V2 client `PLEAZYNG_SIMKL_CLIENT_ID`, read/write scope; distinguish any genuinely owned legacy registration | Own registration and applicable license not verified. Do not set a legacy ID merely to make old tokens appear compatible |
| MDBList | Device Code app | Own public `PLEAZYNG_MDBLIST_CLIENT_ID`; Device Code registration needs no redirect or embedded client secret | Own app/consent/purchase-tier behavior not verified |
| Steam | Relay OpenID; optional Web API catalog | Owned relay return URL; server-only Web API key for catalog. Streaming/families remain separately disabled | Core service deployment does not qualify actual Steam login, catalog access, cloud files, streaming or family operations |
| Google Drive | Native Google sign-in on Android/iOS; PKCE on desktop | Owned platform OAuth clients; Android package/signing certificate and iOS bundle binding; desktop/native return paths must match source; least required scopes | No fork-owned registrations verified. Requested `drive.readonly` can require Google verification; do not claim public availability from a testing client |
| OneDrive | Native public-client PKCE | Owned Entra registration, `ONEDRIVE_CLIENT_ID`, supported account audience and native callback; Files.Read/offline_access plus optional app-folder writes | Own registration/consent and real-device tests pending |
| Dropbox | Native public-client PKCE | Owned scoped app, `DROPBOX_CLIENT_ID`; read metadata/content, optional writes, exact native callback | Own registration and production-access status not verified |

The cloud/source callback target is `pleazyng-source://oauth/callback`; desktop handling must follow the actual loopback branch in `lib/sources/source_oauth.dart`: Google uses an ephemeral loopback port; OneDrive and Dropbox use `http://127.0.0.1:53682/oauth/callback`. Do not register one custom URI for every platform. Preserve legitimate user-supplied client overrides.

## Provider conditions checked against current primary documentation

Trakt supports Device Code for TVs/media centers and permits ordinary free or paid apps under its standard use policy without a separate commercial agreement. Its new-app page requires a verified GitHub account connection. Registration alone does not prove endpoint access or exemption from user Community Apps limits. [Create an app](https://developer.trakt.tv/docs/create-an-app), [authentication](https://developer.trakt.tv/docs/authentication-oauth), [use policy](https://developer.trakt.tv/docs/api-use-policy).

AniList documents free commercial usage below $150 monthly revenue and a commercial-license requirement above that amount. Its restriction on competing/non-complementary tracker services also needs to be respected; a media-player integration should be described accurately, rather than assuming all app features are approved. Current revenue/permission has not been verified. [AniList terms](https://docs.anilist.co/guide/terms-of-use).

Simkl documents free commercial usage below $150 monthly revenue and requires a commercial license at $150/month or more. Keep required attribution/item links, application headers and per-user/application request limits. Revenue and license status are not established by creating a client. [Simkl API rules](https://api.simkl.org/api-rules).

## Activation checks

1. Verify account ownership and save the new public app/client ID. Store confidential fields in approved private secret storage, with a recoverable backup.
2. Confirm displayed app name/icon, exact callback and requested scopes. No generic website redirect may receive an OAuth code or token.
3. Enable only that provider; restart only the owned service if server configuration changed. Preserve the current release qualification source hold; client compile definitions belong in a subsequent qualified revision.
4. Test real consent, cancellation, state/replay rejection, token exchange, refresh/expiry/revoke and actual read/write synchronization. Test the TV QR path where implemented. Keep test tokens and capability URLs out of logs and receipts.
5. Record accepted terms and any commercial permission accurately. Reconnect tokens tied to another registration without discarding unrelated local data. A working health endpoint is not provider qualification.

Discord’s current source uses dynamic HTTPS poster assets, so the uploaded static `pleazyng` asset is available for future use rather than a required client key. No bot/OAuth registration is needed for this existing desktop IPC Rich Presence path. Both public repository variables (`PLEAZYNG_DISCORD_APPLICATION_ID`, `PLEAZYNG_RELAY_BASE_URL`) are staged and read back; current workflow source does not consume them, so this is not activation or end-to-end qualification.

## OAuth hosting split

MyAnimeList and AniList now have a dedicated Cloudflare OAuth implementation,
with unchanged callback URLs and expiring, single-use sessions. The deployment
and provider configuration are independent: an empty AniList secret keeps it
disabled. Trakt browser PKCE and Steam remain on the local Go relay; Trakt TV
sign-in remains direct device-code. See
[Cloudflare OAuth operations](../../server/cloudflare-oauth/README.md) for the
route contract, limits, verification, secrets and rollback. No application
client secret belongs in a release artifact.
