# Podcast support: assessment and implementation

Assessed 30 October 2026 against `snapetech-org/PlezyNG` main `4448858044d10814756527dd02c5604318831b3e`.

## Existing support

- RSS/Atom source adapter: encrypted private feed URL and optional Basic authentication, enclosure playback, artwork, show notes, bounded feed parsing.
- OPML subscription import/export (500 feeds, 2 MiB), profile-scoped sources.
- Shared source player: resume, variable speed, sleep timer, bookmarks, chapters, local downloads and playback ownership.
- Podcasts currently appear as music entries. No dedicated discovery/subscriptions/latest-episodes view.
- Audiobookshelf authenticates and handles books, but treats podcast shows as ebooks because it only reads `media.audioFiles`. Podcast episodes require their own file and progress identity.
- RSS publication dates are passed to ISO-only parsing, so ordinary RFC 822 dates lose their release year. Feed metadata, explicit flags, seasons and Podcasting 2.0 chapters are missing.

Confidence: high in this source assessment; no runtime validation performed.

## Supported integration scope

| Platform / protocol | Integration in this change | Setup / boundary |
| --- | --- | --- |
| Apple Podcasts directory | Search and resolve public show links to RSS, then subscribe and play publisher enclosures | No Apple account. Directory metadata is not a paid Apple subscription entitlement. |
| Podcast Index | Search, trending and show-link lookup to RSS | Optional personal API key/secret in the encrypted profile preference store; no embedded service secret. |
| Audiobookshelf | Podcast libraries, show folders, downloaded episodes, covers, episode-scoped progress | Existing configured server account. Server download management stays in Audiobookshelf. |
| RSS / Atom hosts | Native audio/video enclosure playback and rich episode metadata | Direct feed URL; HTTPS default, explicit HTTP opt-in through source setup. |
| Patreon private podcasts | Existing native private RSS path, surfaced in podcast setup | Creator must enable RSS; paste the member-specific URL. No Patreon account scrape or purchase. |
| OPML podcast apps | Import/export subscriptions through existing controls | Subscription portability; OPML does not transfer play history. |
| Spotify, Amazon Music / Audible, YouTube Music | Assessed, not advertised as native additions | No public RSS entitlement inferred from a service URL. Separate account/SDK or licensed integration required. |

## Implementation checklist

- [ ] Directory client with bounded responses, exact provider-host parsing, no private feed URLs sent to directory search, cache and stale-request protection.
- [ ] Podcast hub in existing Sources navigation: shows, latest episodes, search/status/order/offline filters, refresh, playback, downloads and completion controls.
- [ ] Profile-scoped encrypted optional Podcast Index credentials and explicit disconnect.
- [ ] Existing source setup presets and OPML controls reachable from the hub.
- [ ] RSS/Atom metadata, RFC 822 dates, video enclosures, duplicate suppression and chapter hydration.
- [ ] Audiobookshelf episode browsing, file resolution, artwork and progress routing.
- [ ] Regression fixtures for provider parsing, credential boundaries and episode identity.
- [ ] Source review, documentation and published review branch.

## Verification and constraints

Use the attached GitHub connector for all remote reads/writes. No builds, tests, analyzer, formatter or CI runs in this task. Keep the feature on its own review branch and preserve other active work. Existing workflows are manual dispatch and private JIT only.

Source completion does not establish device behavior, provider availability or release qualification. Validation should cover private-feed redirects, profile changes during requests, a real Audiobookshelf podcast library, resumed/offline playback, keyboard/remote traversal and long/RTL text.

## Primary references

- [Apple Search API](https://performance-partners.apple.com/search-api) — podcast search and lookup.
- [Podcast Index OpenAPI](https://podcastindex-org.github.io/docs-api/pi_api.json) — endpoints and SHA-1 request authentication.
- [Audiobookshelf API](https://api.audiobookshelf.org/) — podcast media schema, files and per-episode progress.
- [Patreon private RSS](https://support.patreon.com/hc/en-us/articles/360041347732-How-to-use-your-audio-RSS) — member feed support.
- [Podcasting 2.0 chapters](https://podcasting2.org/docs/podcast-namespace/tags/chapters) — external JSON chapter resources.
- [Spotify episode API](https://developer.spotify.com/documentation/web-api/reference/get-an-episode) — account-scoped metadata; not an RSS enclosure contract.
