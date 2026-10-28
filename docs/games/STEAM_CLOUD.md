# Steam Cloud files

The game detail view can list, download, replace and delete Steam Cloud files
through Valve's documented ICloudService. This is an **eligible-AppID integration**,
not general access to every purchased game's saves. It is disabled unless the
operator configures a Valve-approved OAuth client and exact AppID allowlists.
Steam Families management remains a confirmed handoff to Steam's account UI;
there is no implemented or advertised general Families mutation API.

## Eligibility and deployment

Obtain a client ID from Valve for cross-platform Cloud access, the intended
AppIDs, `read_cloud` / `write_cloud`, token lifetime and the exact HTTPS callback
`${OAUTH_BASE_URL}/auth/steam-cloud/callback`. A publisher Web API key and the
existing Steam OpenID/catalog connection are insufficient. PlezyNG-specific
approval has not been established.

Set the four variables in [steam-cloud.env.example](../../server/steam-cloud.env.example).
The Compose service forwards them. `WRITE_APPIDS` must be a subset of `READ_APPIDS`.
Configure exact reviewed storage DNS names for the approved games. Empty/invalid
configuration disables the integration. No wildcard storage trust or fallback to
HTTP is permitted. API egress is fixed to `api.steampowered.com`; storage egress is
HTTPS, redirects are rejected, all resolved addresses must be public, and the
validated address is used directly for dialing to prevent DNS rebinding. Preserve
TLS hostname verification. The proxy must permit 12 MiB JSON requests and at least
130 seconds of upstream response time. Do not log request bodies, Authorization
headers, upstream token query strings or signed storage URLs.

The service retains only opaque grants and upstream tokens in process memory.
Restarting it invalidates sessions; it cannot resume an interrupted mutation.
Deployment with multiple replicas requires sticky routing for the existing OAuth
session and Cloud grant. Cross-replica mutation locking is not implemented: keep
this optional feature on a single process until a shared locking/grant service is
introduced. Valve's batch protocol remains authoritative across Steam clients.

## User flow and authorization

1. Open a Steam game's detail view and choose **Steam Cloud files**. If its AppID
   is not eligible, the existing reviewed Steam browser destination is offered.
2. Connect through the existing QR/browser authorization dialog. The server
   verifies the token's SteamID and actual read access; browser-provided SteamID
   and catalog identity alone cannot authorize files.
3. The initial grant is read only. Download uses the system save picker. Choose
   **Allow Cloud changes** to authorize a separate write-capable grant; the old
   grant is revoked first.
4. Close the game on every computer, let Steam finish syncing and download a
   backup. Replacement and permanent deletion each require a file-specific review.
5. Close the view or change profile to cancel operations and revoke the app grant.
   Grants expire after 30 minutes and also expire with/revoke with the catalog
   identity. Revoking an app grant does not revoke the upstream token at Valve;
   it discards the server's copy. OAuth token lifetime is agreed with Valve.

Limits are 2,000 files per listing and 8 MiB per transfer. Cloud names are opaque
keys, never server/local filesystem paths. The UI strips directories only when
suggesting a download filename; the platform picker controls the destination.
The API supports a new filename with an empty expected hash; the current UI
intentionally limits upload to replacing a listed save. All platforms share the
same focusable controls, RTL isolation, localized size/date presentation and
profile cancellation. New untranslated strings use explicit English fallbacks.
System file-picker availability, including TV platforms, needs device qualification.

## Mutation semantics

A grant binds one verified SteamID, AppID and read/write capability. Every action
checks that the original catalog authorization is still live. Only one operation
per account/AppID runs at a time, with at most eight active operations. Reads have
bounded responses; request bodies and file buffers have fixed limits.

Each mutation refreshes the current SHA1 first and rejects stale or blind
replacement/deletion. This is **not atomic compare-and-swap** against a game or
another Steam client. The batch sequence is BeginAppUploadBatch, BeginHTTPUpload,
signed PUT, CommitHTTPUpload, CompleteAppUploadBatch; deletion uses the same batch
finalizer. Both finalizers run with bounded independent cleanup contexts after a
cancelled/failed transfer. HTTP 200 is not sufficient: `x-eresult` is checked.
Existing platform restrictions are preserved, uint64 IDs never round through a
floating point number, and downloads verify length and Steam's SHA1 checksum.

There is no automatic mutation retry, rollback or recovery of deleted versions.
An ambiguous error clears the listing and requires refresh/review. Disconnecting
may occur after Steam applied a mutation; cancellation cannot promise rollback.
Operation work is bounded to 90 seconds plus two 15-second cleanup budgets.
Authenticated transfer responses extend the normal HTTP write deadline to 125
seconds. The app has a hard 125-second request timeout and revokes on retirement.

## Qualification

Server contract/race tests exercise grant separation, identity mismatch, replay,
read-only rejection, expiry/revocation, exact uint64 batches, failed/cancelled
transfer cleanup, stale-file rejection, storage URL policy and integrity checks.
Flutter tests cover request boundaries, revocation, no automatic retry and the
read→write→review flow at narrow RTL/large text.

These are simulated contracts, not evidence of Valve approval or successful
production save mutation. Live handoff must verify the approved client callback,
GetTokenDetails/EnumerateUserFiles response shapes, storage origins and scopes;
back up a disposable test game's saves before upload/delete/conflict tests. Test
an account mismatch, denial, profile change mid-upload, lost response after a
successful PUT, concurrent game sync, readonly AppID, and oversized save. Inspect
logs for secrets without publishing their contents. Keep Families actions in
Steam's own UI and test the signed-in account warning.

Primary references checked 2026-10-28:

- [Steam OAuth](https://partner.steamgames.com/doc/webapi_overview/OAuth)
- [ICloudService](https://partner.steamgames.com/doc/webapi/ICloudService)
- [Steam Families](https://partner.steamgames.com/doc/features/families)
