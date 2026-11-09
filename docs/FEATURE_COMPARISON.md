# Plex, Plezy and Pleazyng comparison notes

Reviewed **2026-11-09**. This is the evidence and gap register for the
[README comparison](../README.md#feature-comparison). Features are grouped by
workflow rather than listing every setting as a separate capability.

Pleazyng is a fork of Plezy: an inherited capability belongs in both columns.
The audit used upstream Plezy's
[README at `738e18fdc552ace910dedabf6e689ab74e1dae58`](https://github.com/edde746/plezy/blob/738e18fdc552ace910dedabf6e689ab74e1dae58/README.md)
and source tree, plus Pleazyng main at `68b0378b92fdbeab4dfcdc01deec7bb212725579`
and the linked implementation guides. The current published package set is
[Pleazyng 3.0.7](https://github.com/snapetech-org/pleazyng/releases/tag/v3.0.7).
The snapshot author and the independently verified upstream inventory are
credited in the [source ledger](../UPSTREAM_ATTRIBUTION.md#feature-inventory-reference).

The Plex column covers official Plex clients and, where named, Plex Media
Server, Plexamp, Plex Photos and Plex Dash. It therefore includes some server
and service capabilities that a client application cannot replace. A dash
means no equivalent built-in workflow was found in the audited inventories;
it is not a claim that no plugin, external program or future version can do it.
An external link, data import or similar-looking control is not automatically
an implementation of another product's service or protocol.

**Implemented**, **packaged**, **device-qualified** and **generally available**
are different states. The README retains Experimental and Partial labels and
links the limitations. A successful package build does not establish every
device, provider or media-format combination. Plans with a requirement ledger
are evidence only for rows marked implemented or partial, not for their whole
requested scope.

## Plex capabilities and remaining gaps

### Browser client

Plex Web provides a browser player and server-management interface. Neither
Plezy nor Pleazyng currently supplies an equivalent complete web client.
Pleazyng's Linux book-reading browser surface and temporary LAN media tools do
not replace it. [Plex Web documentation](https://support.plex.tv/articles/200288666-opening-plex-web-app/).

### Device coverage

Plex distributes clients for additional device families, including Roku,
PlayStation and Xbox. These are not Plezy or Pleazyng build targets. Shared
desktop, handheld and TV targets should not be presented as fork exclusives.
[Official Plex app/device inventory](https://www.plex.tv/apps-devices/).

### Plex-hosted content

Plex's own free movies/shows and FAST channels are licensed streaming services,
not ordinary personal-server libraries. Neither fork implements that service's
playback. Personal-server Live TV is inherited; Pleazyng's separate IPTV sources
are documented in the [IPTV implementation plan](plezyng/iptv/PLAN.md).
[Plex video-on-demand overview](https://support.plex.tv/articles/video-on-demand-overview/).

### Rentals and purchases

Supported Plex apps can play Plex movie rentals and purchases where available.
Neither fork implements this licensed library. Pleazyng's
[official storefront handoffs](plezyng/service-integrations/README.md) open
external services and do not grant playback rights or import purchases.
[Plex rentals and purchases](https://support.plex.tv/articles/rentals-purchases-on-plex/).

### Photo libraries

Plex supports personal photo libraries through Plex Photos and Plex Web,
including photo browsing and slideshows. The audited fork clients have no
equivalent Plex photo-library interface. Artwork, comic pages and an artwork
screensaver do not supply it.
[Plex library-view documentation](https://support.plex.tv/articles/200392126-using-the-library-view/),
[Plex product overview](https://support.plex.tv/articles/202526943-plex-free-vs-paid/).

### Social and Lists

Plex social profiles and shareable Discover Lists belong to its service.
Inherited Discover/watchlist access does not reproduce the full social product.
Pleazyng's [Saved picks and co-present voting](plezyng/swipe/DELIVERY.md) are a
different, local decision workflow.
[Plex profiles](https://support.plex.tv/articles/profile/),
[Plex Lists](https://support.plex.tv/articles/lists/).

### Plexamp specialized features

Plexamp has dedicated Sonic Adventure, Guest DJ and Sonic Sage interfaces.
Neither fork provides these interfaces; ordinary Instant Mix is inherited.
Plexamp also already offers gapless playback, loudness leveling, Sweet Fades,
visualizers and an equalizer. Those broad categories are not Pleazyng-only
features. The fork's importable native preset packs and MPV effects are the
specific additions compared in the README.
[Plexamp feature inventory](https://www.plex.tv/plexamp/).

### Car and voice integrations

Plexamp integrates with CarPlay, Android Auto and Siri. Neither fork documents
equivalent integrations. Detecting Android Automotive for layout purposes is
not Android Auto projection. [Plexamp platform features](https://www.plex.tv/plexamp/).

### Headless music

Plexamp offers a Plex Pass headless Raspberry Pi endpoint. The fork clients
do not implement an equivalent managed endpoint.
[Plexamp headless support](https://www.plex.tv/plexamp/).

### Companion protocol

The Plex ecosystem has Companion controller/receiver integrations and supported
Alexa/Sonos routes. Plex's Companion article explicitly excludes its newer
mobile-app experience, so support must be checked per app/device. Plezy Remote
uses its own protocol; Pleazyng's [Android automation bridge](plezyng/android-automation.md)
does not register the app as a native Plex Companion receiver.
[Plex Companion support](https://support.plex.tv/articles/203082707-supported-plex-companion-apps/),
[Plex device inventory](https://www.plex.tv/apps-devices/).

### Server-owned capabilities

Plex Media Server owns hosting, sharing permissions, library analysis, optimized
versions, tuner/DVR processing and hardware transcoding. Plex Web and Plex Dash
provide administration and monitoring. Neither fork replaces these services.
Both retain their supported client controls, including metadata editing and
backend-dependent DVR scheduling; lack of a complete administration console
does not mean those controls are missing.
[Plex overview](https://support.plex.tv/articles/200288286-what-is-plex/),
[Plex Pass feature overview](https://support.plex.tv/articles/201751006-plex-pass-feature-overview/).

Plex's own server/account requirements remain authoritative. Do not describe
either client as granting Plex Pass, bypassing server entitlements or supplying
server-side hardware transcoding. Official requirements also vary by client and
account. See [remote playback requirements](https://support.plex.tv/articles/requirements-for-remote-playback-of-personal-media/)
and [Downloads requirements](https://support.plex.tv/articles/downloads-overview/).

### Server subtitle Auto-Sync

Plex has server-assisted external-SRT Auto-Sync using analyzed audio, with
documented Plex Pass/server requirements. The audited fork code does not expose
an equivalent Plex Auto-Sync request workflow. Pleazyng's local cue alignment,
two-anchor correction, transcription and revision tools are separate features;
see the [subtitle implementation ledger](plezyng/subtitles/PLAN.md) and
[qualification record](plezyng/subtitles/QUALIFICATION.md).
[Plex Auto-Sync documentation](https://support.plex.tv/articles/auto-sync-subtitles/).

## Inherited Plezy baseline

The [pinned upstream inventory](https://github.com/edde746/plezy/blob/738e18fdc552ace910dedabf6e689ab74e1dae58/README.md)
covers Plex/Jellyfin/Emby libraries, music, personal-server Live TV, collections,
playlists, search, duplicate copies, downloads, watch-state sync, profiles,
metadata/artwork editing, trackers, Seerr, Open Watch Party, Plezy Remote and
platform playback controls. These belong in both fork columns. The detailed
[README feature list](../README.md#features) remains the user-facing inventory.

In particular, multi-server search, Trakt/MyAnimeList/AniList/Simkl, Seerr
requests, ASS/SSA rendering, MPV shaders and Android external-player progress
handoff originated upstream. Pleazyng extends this baseline rather than
claiming to have introduced every item. Both projects use GPL-3.0 for their own
application source; see [our license](../LICENSE) and
[upstream's license](https://github.com/edde746/plezy/blob/738e18fdc552ace910dedabf6e689ab74e1dae58/LICENSE).

Plex also has many shared playback capabilities. For example, its
[speed controls](https://support.plex.tv/articles/video-playback-speed-controls/)
and [Watch Together](https://support.plex.tv/articles/watch-together/) have their
own app/entitlement constraints. Plex says Watch Together is being retired from
the new native app experience while retained in Web. The forks' Open Watch
Party supports users playing their own copies across three server backends;
that is the distinction, not an assertion that Plex never offered group watch.

## Client playback extensions

Pleazyng's [download, Home, pre-play and profile additions](plezyng/HANDOFF.md#implemented-in-this-work-branch)
extend inherited workflows. Its [audio effects and media tools](VLC_FEATURE_PARITY.md)
and [subtitle tools](plezyng/subtitles/PLAN.md) likewise add controls to existing
playback. Plex already offers music EQ and subtitle synchronization.

The local Sweet Fades path uses available Plex loudness information and is
opt-in; it is not a replacement for Plexamp's Sonic analysis features. Recorded
commercial skipping uses supplied timeline markers; it does not remove ads from
Plex's hosted streaming service. Plex already has
[commercial detection/skipping](https://support.plex.tv/articles/115003944134-removing-commercials/).
Implementation: [music playback service](../lib/services/music/music_playback_service_impl.dart),
[commercial-skip control](../lib/widgets/video_controls/widgets/skip_marker_button.dart).

## Native TV ports

Pleazyng adds [LG webOS](maintainers/webos-tv.md) and
[Samsung Tizen](maintainers/tizen-tv.md) packages to the upstream target set.
Plex already has official apps for both families. Pleazyng's release assets are
native packages, not a claim of store approval or universal TV compatibility.
LG native playback, eARC audio, SUP-sidecar overlays and diagnostics have their
own model/firmware limits. Embedded Matroska PGS extraction and complete
no-burn subtitle negotiation remain unfinished. Tizen installation requires
appropriate signing; physical Samsung playback remains unqualified. Consult
the port guides before selecting a package for a particular TV.

## Retired Plex services and distinct additions

Plex's podcast service ended in 2022; Pleazyng's
[RSS/Atom podcast sources](plezyng/podcasts/IMPLEMENTATION.md) are independent.
Plex Arcade also ended in 2022 and was not a GameStream receiver. Pleazyng's
[game receivers and RomM integration](../README.md#games--home-streaming) have
their own experimental/partial status.
[Plex podcast retirement notice](https://forums.plex.tv/t/podcasts-and-web-shows-are-going-away-on-april-15-2022/787096),
[Plex Arcade retirement update](https://www.plex.tv/blog/game-on-a-plex-blog-story/).

## Keeping the comparison accurate

When updating the chart, refresh the date and upstream revision, inspect source
and current official Plex documentation, and move rows out of the unique section
when upstream gains an equivalent. Keep each distinct feature linked to its
in-repo guide or gap entry. Preserve platform, provider, signing and runtime
limits instead of turning every source implementation into an unqualified Yes.

Use canonical `pleazyng://` in examples. Legacy fork schemes are compatibility
aliases, not the generated scheme, and the upstream scheme is not registered.
Implemented Dolby Vision/FEL and NPU experiments belong in normal compatible
builds with persisted Settings opt-in, off by default; device qualification is
reported separately. Do not reintroduce a separate experimental-app build gate.
