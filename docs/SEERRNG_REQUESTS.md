# Minimal Requests

## Quiet requests while browsing

With a linked SeerrNG account, a movie or show with an exact TMDB identity gains a small action in its existing title controls and card context menu. The action follows its scope: **Request**, **Request missing seasons**, **Requested**, **Notify me when available**, or **Available**. A playable library copy keeps its normal Play action; where configured, an extra action offers **Request in 4K** for a movie or show, or **Request missing seasons** for a show. On a library show detail, Pleazyng checks aired TV seasons against SeerrNG's stored season coverage, so a new season can be offered even before it has a stored SeerrNG row. Library items resolve their TMDB identity from their own Plex/Jellyfin/Emby server rather than a fuzzy title match. Unsupported kinds and unresolved IDs have no request action.

For a movie with a configured default destination on SeerrNG, pressing Request submits it once and updates the existing badge. A TV show opens the current season selector; a catalog item whose source agrees on an exact TMDB season number preselects only that season. The existing sheet remains responsible for availability, permissions, 4K and advanced destination choices. An in-flight quick request is guarded against a second press, and SeerrNG uses the supplied idempotency key to recover a committed request whose response was lost.

If another viewer requested a title, **Notify me** uses SeerrNG's own availability notification preferences. Where the server supports the scope, a 4K alert waits for 4K and a season alert waits for that season. The title action can turn the alert off. The app never displays the other requester's identity. Request status and playback are separate: SeerrNG's available state does not manufacture a Play button until the active profile has a verified, usable library copy.

State reads for visible cards are coalesced into batches of at most 40 and cached within the active profile's Seerr session for two minutes. A request, notification change, permission refresh or profile switch invalidates the relevant state. A server without the new endpoint retains the older movie/TV request sheet; Pleazyng does not assume scoped notifications or fast submission on those servers.

Connect your instance in **Settings → Services → Seerr**. **Requests** appears in the desktop/TV sidebar and mobile navigation's additional destinations. It follows the profile's Explore visibility and local action-PIN controls. Its Seerr connection is independent of media-server availability: an offline Plex/Jellyfin/Emby server does not hide Requests. Your request instance itself still needs to be reachable.

Choose **Movies**, **TV Shows**, **Ebooks** or **Audiobooks**. The default view lists the signed-in user's requests and their state. **Discover** shows that category's catalog; enter a title and submit Search to find something specific. Refresh updates status, and Load more retrieves another bounded page.

Select a title to see its basic description and current state. **Request** submits a movie/book or opens the existing TV season selector. Available and already-requested items are distinguished; ebook availability does not imply audiobook availability. **View All** opens that title's collection/details page in your instance. The server remains authoritative for permissions, quotas, service availability, existing requests and approval rules.

The minimal flow does not fetch service configuration or expose 4K, quality, destination, approval, denial or administrative editing controls, including for administrator accounts. Existing advanced request flows elsewhere remain available. User requests use server defaults and never impersonate another user.

## Compatibility and qualification

Book discovery, format filtering and requests require SeerrNG's book APIs and an enabled corresponding service/category. Existing Seerr/Overseerr movie/TV discovery and requesting continue to use their established client. A server lacking the book APIs reports a load failure; it does not acquire or play books through this screen. Account setup, administrator approval, destinations and provider availability remain responsibilities of the instance.

SeerrNG can route ebooks and audiobooks to BookOrbit when its administrator connects BookOrbit under **Settings → Services → Book Acquisition Services**. The Requests screen needs no new provider setup: it submits the same format-specific SeerrNG request, then displays SeerrNG's approval and availability state. To read or listen in Pleazyng, add BookOrbit as a separate source under **Sources → Add Source** using your own BookOrbit account. See [BookOrbit integration](BOOKORBIT.md).

The client contract was reviewed against [SeerrNG source `2f5793b66f`](https://github.com/snapetech-org/seerrng/tree/2f5793b66f42f0adf7e77ab084c13bc8d22670c9): `/request`, `/request/status`, `/discover/books`, `/search`, `/book/:id` and format-aware availability. The native request UI reuses the existing profile-bound Seerr client and TV season selector. Profile replacement invalidates in-flight reads and removes old details/actions; server-side permission changes are applied through the established account refresh path.

Automated validation covers the four discovery/search categories, authentication, ownership filtering, bounded pagination, exact book request payloads, format-specific availability, minimal mode for an administrator, existing TV season requests, profile changes during delayed responses, sidebar presence/focus/visibility and media-server independence, and phone/tablet/desktop layouts at 200% text. These are API-fixture and Flutter widget tests; live acquisition against an authenticated SeerrNG instance and physical-device qualification are not claimed.

## Request source

This feature implements the downstream proposal [#267](https://github.com/snapetech-org/pleazyng/issues/267) by [@Tatsu941](https://github.com/Tatsu941). It is a downstream implementation, not a newly imported upstream Plezy contribution. Existing upstream credits remain in [UPSTREAM_ATTRIBUTION.md](../UPSTREAM_ATTRIBUTION.md).
