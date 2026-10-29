# Steam Cloud files

The game detail view can list, download, replace and delete Steam Cloud files
through Valve's documented ICloudService. This is an **eligible-AppID integration**,
not general access to every purchased game's saves. It is disabled unless the
operator configures a Valve-approved OAuth client and exact AppID allowlists.
Steam Families uses a separate, disabled-by-default client-service integration;
see [STEAM_FAMILIES.md](STEAM_FAMILIES.md). It does not inherit Cloud authority.

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
logs for secrets without publishing their contents. Qualify the separate Families
flow using its own authorization and review cases.

Primary references checked 2026-10-28:

- [Steam OAuth](https://partner.steamgames.com/doc/webapi_overview/OAuth)
- [ICloudService](https://partner.steamgames.com/doc/webapi/ICloudService)
- [Steam Families](https://partner.steamgames.com/doc/features/families)

## Global sync settings

The authenticated host's **Cloud and game settings on computer** action opens
Steam's game properties after confirmation. Account-wide sync is changed in
Steam Settings → Cloud. This is a host-assisted workflow, not a programmatic
account-global mutation. `ISteamRemoteStorage::SetCloudEnabledForApp` belongs to
the calling game's AppID; `IsCloudEnabledForAccount` is read-only. PlezyNG does not
impersonate other AppIDs or modify guessed private VDF keys. A general programmatic
account toggle remains blocked on a legitimate Valve/host-client write contract.


Re-audited 2026-10-29: the Steam client's published protobuf mirror
[`steammessages_cloud.steamclient.proto` at `89b77382`](https://github.com/SteamTracking/Protobufs/blob/89b77382edac5f747bfc196c2edf8996a7fe92bc/steam/steammessages_cloud.steamclient.proto)
contains Cloud file, sync, batch and session methods, but no global-enable RPC.
An [unversioned reverse-engineered IClientRemoteStorage header](https://github.com/emily33901/SteamStructs/blob/master/IClientRemoteStorage.h)
does name `SetCloudEnabledForAccount(bool)`, with `unknown_ret`. This means an
internal method has been observed; it does **not** establish a versioned ABI,
authorization model or safe public third-party call. Neither guessing its vtable
slot nor adding a disabled adapter would complete the feature. The actual
account-wide programmatic toggle remains unimplemented pending a verified
contract. Supported Cloud file operations and explicit host settings assistance
remain available under the separate permissions described above.

### Additional client-settings contract evidence — 2026-10-29

The broader client-settings path provides a stronger candidate than the old
unversioned native vtable. It does not yet supply an implemented or live-verified
PlezyNG write transport:

- Steam's extracted [`CMsgClientSettings` schema at `c0c1e745`](https://github.com/SteamTracking/Protobufs/blob/c0c1e745cdc042dbde122ed31f40ecde28ca534e/steam/steammessages_clientsettings.proto)
  defines optional boolean `cloud_enabled`, field **10000**, stored in
  `ConfigStore_UserRoaming` as `Software\\Valve\\Steam\\CloudEnabled`, with
  `setting_default_bool = true`. This is source evidence of the setting's
  identity; it is not an instruction to edit a live VDF file.
- Decky's maintained-at-that-revision [`Settings` interface at `83260002`](https://github.com/SteamDeckHomebrew/decky-frontend-lib/blob/83260002908202586356917f07ec391c5bdea975/src/globals/steam-client/Settings.ts)
  declares `SteamClient.Settings.SetSetting(base64): Promise<boolean>` for a
  serialized `CMsgClientSettings`, and
  `RegisterForSettingsArrayChanges(callback): Unregisterable` for observation.
  This is a community interface definition for code running inside Steam's UI,
  not a Valve-supported remote Web API or an OAuth scope.
- PlezyNG currently has no installed Steam UI extension or authenticated bridge
  into that JavaScript context. Its Companion pairing and Cloud OAuth grants do
  not create access to `SteamClient.Settings`. No Steam client executable is
  available in this development environment for an actual write/readback test.

Confidence is **high** in the pinned declarations, **moderate** that this is a
viable host-extension route, and **unknown** in its behavior on the user's current
Steam builds. The previous conclusion that the Cloud service schema offers no
global-enable RPC still holds for that schema; it must not be generalized to say
that Steam has no internal setting-write mechanism.

A verified integration needs all of the following evidence, before its UI can
report a completed change:

1. An explicitly installed host extension can observe the current Steam account
   and this setting on an identified Steam build. Absent protobuf fields must
   remain unknown until the client's default/presence behavior is established;
   absence must not be treated as `false`.
2. A narrowly scoped, authenticated Companion bridge permits only this setting,
   binds the selected host and SteamID, checks the reviewed prior value, rejects
   replay/expired requests and retires access on profile/account changes. It
   must not expose general JavaScript evaluation or automatically enable CEF
   remote debugging.
3. An explicit user-confirmed change sends only field 10000, checks the setter's
   result, then observes the requested state through the client callback.
   Timeout is an unknown outcome, not success and not an automatic retry.
4. A disposable account verifies enable and disable, unchanged unrelated
   settings, restart persistence, account switching and behavior on another
   signed-in computer. `UserRoaming` metadata alone does not prove propagation
   timing or authorize a claim that all computers changed immediately.

No toggle, extension or mock-backed adapter is claimed implemented by this
research update. Cloud file permissions remain separate from this candidate
host-client settings capability.
