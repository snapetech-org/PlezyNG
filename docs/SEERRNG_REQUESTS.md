# Minimal Requests

Connect your instance in **Settings → Services → Seerr**. **Requests** appears in the desktop/TV sidebar and mobile navigation's additional destinations. It follows the profile's Explore visibility and local action-PIN controls. Its Seerr connection is independent of media-server availability: an offline Plex/Jellyfin/Emby server does not hide Requests. Your request instance itself still needs to be reachable.

Choose **Movies**, **TV Shows**, **Ebooks** or **Audiobooks**. The default view lists the signed-in user's requests and their state. **Discover** shows that category's catalog; enter a title and submit Search to find something specific. Refresh updates status, and Load more retrieves another bounded page.

Select a title to see its basic description and current state. **Request** submits a movie/book or opens the existing TV season selector. Available and already-requested items are distinguished; ebook availability does not imply audiobook availability. **View All** opens that title's collection/details page in your instance. The server remains authoritative for permissions, quotas, service availability, existing requests and approval rules.

The minimal flow does not fetch service configuration or expose 4K, quality, destination, approval, denial or administrative editing controls, including for administrator accounts. Existing advanced request flows elsewhere remain available. User requests use server defaults and never impersonate another user.

## Compatibility and qualification

Book discovery, format filtering and requests require SeerrNG's book APIs and an enabled corresponding service/category. Existing Seerr/Overseerr movie/TV discovery and requesting continue to use their established client. A server lacking the book APIs reports a load failure; it does not acquire or play books through this screen. Account setup, administrator approval, destinations and provider availability remain responsibilities of the instance.

The client contract was reviewed against [SeerrNG source `2f5793b66f`](https://github.com/snapetech-org/seerrng/tree/2f5793b66f42f0adf7e77ab084c13bc8d22670c9): `/request`, `/request/status`, `/discover/books`, `/search`, `/book/:id` and format-aware availability. The native request UI reuses the existing profile-bound Seerr client and TV season selector. Profile replacement invalidates in-flight reads and removes old details/actions; server-side permission changes are applied through the established account refresh path.

Automated validation covers the four discovery/search categories, authentication, ownership filtering, bounded pagination, exact book request payloads, format-specific availability, minimal mode for an administrator, existing TV season requests, profile changes during delayed responses, sidebar presence/focus/visibility and media-server independence, and phone/tablet/desktop layouts at 200% text. These are API-fixture and Flutter widget tests; live acquisition against an authenticated SeerrNG instance and physical-device qualification are not claimed.

## Request source

This feature implements the downstream proposal [#267](https://github.com/snapetech-org/pleazyng/issues/267) by [@Tatsu941](https://github.com/Tatsu941). It is a downstream implementation, not a newly imported upstream Plezy contribution. Existing upstream credits remain in [UPSTREAM_ATTRIBUTION.md](../UPSTREAM_ATTRIBUTION.md).
