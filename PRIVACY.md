# Pleazyng Privacy Notice

Effective October 25, 2026

Pleazyng is a media client. It does not create a Pleazyng account, host your media, or send your library to a Pleazyng server. The app stores its working data on your device and connects to the media servers and other services you choose to use.

## Data stored on your device

Pleazyng stores app settings, server and profile details, library preferences, and information needed to resume playback. It may also store authentication tokens for the services you connect, downloaded media, and diagnostic logs. Tokens are protected with platform secure storage where supported; other app data is kept in the app's local storage. Clearing app storage or uninstalling removes local app data. Media saved to a folder you selected may remain there and can be deleted separately.

## Connections to other services

When you sign in or use a feature, Pleazyng sends the requests needed for that feature to the service you selected. This can include Plex, Jellyfin, or Emby servers; Plex account and discovery services; optional services you connect for tracking, requests, recommendations, or media information; a Watch Together relay you configure; a WebDAV endpoint you configure for backups; and a Cast receiver you choose. Those services receive the information needed to answer the request, such as account credentials or tokens, server and media identifiers, playback actions, and network details. Each service handles that information under its own privacy terms.

Standalone video metadata lookup is off by default for file sources. If you enable it, opening a video's details can send a cleaned filename title, optional year, detected episode numbers, or an existing NFO catalog identifier to Trakt for matching. The video file, full source path and source credentials are not sent for that lookup. If you enable encrypted progress and notes sync, the configured WebDAV or cloud-drive storage provider receives the sync files; cloud-drive write access is requested only for this feature. Settings backup is a separate WebDAV upload containing the portable settings export. Review the destination and exported settings before enabling either service.

Store purchases are handled by the store where you got the app. Pleazyng does not receive your payment card details.

Pleazyng does not use advertising or analytics SDKs. The standard store build workflow does not include Sentry crash reporting. Other builds can include optional crash reporting; when included and enabled in Settings, diagnostic events may be sent to Sentry. You can turn off crash reporting in the app settings.

Release builds can check GitHub for Pleazyng updates. When a check runs, GitHub receives the request and ordinary network information such as your IP address.

## Sharing and retention

Pleazyng maintainers do not receive your media library, server credentials, or playback history through a Pleazyng service. Information remains on your device unless you direct the app to send it to a connected service, export and share a log or backup, or contact the maintainers. Connected services apply their own retention rules. Logs and backups can contain device or server details, so review them before sharing.

You can remove local app data by deleting it in the app where supported, clearing the app's storage, or uninstalling the app. Media saved to a user-selected folder may remain there. To remove information held by a media or third-party service, use that service's account controls.

## Disconnecting accounts and deleting data

Pleazyng does not create or operate a Pleazyng user account. You can connect accounts that you already have for services such as Plex, Jellyfin, and Emby. Removing a server or service connection in Pleazyng removes that connection from the app, but does not delete the account or server data held by that service.

To delete an account held by a connected service, use that service's account controls. For a self-hosted Jellyfin or Emby server, contact the server administrator. Pleazyng cannot delete accounts, media, or playback data held by those services. To remove data stored locally by Pleazyng, remove the connection in the app, clear the app's storage, or uninstall it. Downloads saved to a folder you selected may need to be deleted separately.

## Contact

For privacy questions, use the [Pleazyng GitHub project page](https://github.com/snapetech-org/PlezyNG/issues). GitHub issues are public; do not include passwords, access tokens, server addresses, or other sensitive information in an issue.

We may update this notice when the app's data practices change. The effective date above will change with each revision.


## Trakt integration

Connecting Trakt is optional. When connected, Pleazyng reads your account details, watch history, ratings and lists for the features you use. Playback scrobbling and watched-state sync send playback events or changes to your own Trakt account when you enable those features. Metadata searches send the search title and identifiers, not your media files or source credentials. Trakt data is used within Pleazyng for these features; it is not sold or provided as a catalog or data feed to other services.

TV devices use Trakt's device-code authorization. Browser-capable devices use S256 PKCE through a SnapeTech-owned HTTPS callback. The callback service temporarily holds the verifier and authorization result in memory for up to ten minutes; a result can be retrieved only once. It does not persist or log Trakt tokens. No Trakt client secret is included in the app. Account tokens and cached data remain on your device for your connection and selected features.

Disconnect Trakt in Settings → Services → Trakt to stop account access, remove the local connection and attempt to revoke its token. You can also revoke Pleazyng in Trakt's connected-app settings. Disconnecting does not erase history or lists on Trakt; use Trakt's account controls to manage or delete that data. Clear Pleazyng's app storage to remove remaining local caches. For help with data you sent directly to SnapeTech support, contact support@snape.tech; we retain support correspondence only as needed to handle your request and applicable recordkeeping obligations.

Pleazyng uses Trakt but is not endorsed or certified by Trakt.
