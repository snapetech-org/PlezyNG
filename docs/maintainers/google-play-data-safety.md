# Google Play Data safety basis

Source review and console preparation: 2026-11-05. Applies to the standard store
build without Sentry crash reporting or advertising/analytics SDKs. Recheck when
SDKs, defaults, or data flows change.

Google defines collection as sending data off device, including direct transfers
to a third party. No SnapeTech backend is needed for a transfer to fall within
that definition. User-initiated transfers to an explicitly connected service
can qualify for the sharing exception; that does not exempt collection.

The prepared types are optional; users can use local file sources without
connecting media-server, tracking, or backup accounts. No claim is made that all
traffic is encrypted: user-configured HTTP media servers are supported and the
Android manifest explicitly enables cleartext traffic.

| Type | Source / purpose |
| --- | --- |
| Name | Media-server usernames and explicitly selected Watch Together display name; functionality/account management |
| Email address | Existing-account login where an email is used as the username; functionality/account management |
| User IDs | Connected media-server/tracker identity and authentication; functionality/account management |
| Files and docs | Explicit settings export uploaded to the user's configured WebDAV endpoint; functionality |
| App interactions | Playback state/watch tracking sent to connected servers/trackers; functionality/personalization |
| In-app search history | Search queries sent to selected media services; functionality |
| Other user-generated content | User-created playlist and collection titles sent to their media server; functionality |
| Device or other IDs | Client/device identifiers sent during media-server authentication; functionality/account management |

Do not assert ephemeral processing across these flows: connected servers can
retain account, device, playback, playlist and backup records. No advertising,
marketing or analytics purpose is selected. No maintainer-operated user-account
creation is provided; existing Plex accounts or server-administrator-created
Jellyfin/Emby accounts can connect. Local account removal and third-party account
controls are explained in PRIVACY.md; the app cannot promise deletion from a
third party's service on the maintainer's behalf.

Examples checked: `lib/services/jellyfin_auth_service.dart`,
`lib/services/jellyfin_client/parts/playlists.dart`, Plex/Jellyfin search methods,
`lib/services/trackers/trakt/trakt_client.dart`,
`lib/watch_together/providers/watch_together_provider.dart`,
`lib/services/cloud_settings_backup_service.dart`, and
`android/app/src/main/AndroidManifest.xml`.

[Google's collection and sharing definitions](https://support.google.com/googleplay/android-developer/answer/10787469)
are the basis for these declarations. Console completion and review outcome are
recorded separately in pleazyng-channel-migration.json.
