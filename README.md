<a href="https://plezyng.app/">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/branding/pleazyng-artwork-dark.webp">
    <img src="assets/branding/pleazyng-artwork-light.webp" alt="Pleazyng — coral folded-ribbon identity" width="840">
  </picture>
</a>

<p>
  <a href="https://plezyng.app/"><strong>plezyng.app</strong></a>
</p>

A cross-platform media client for Plex, Jellyfin, Emby, standalone files, books, music, and podcasts, maintained as a fork of [Plezy](https://github.com/edde746/plezy).

Pleazyng is a downstream fork for feature requests that Plezy upstream has declined, left open, or not yet shipped. The table below maps those upstream gaps to the corresponding downstream implementation.

See [Files, books and listening](docs/FILES_AND_BOOKS.md) for standard/cloud sources, readers and offline behavior, and [Public-library setup](docs/LENDING_SETUP.md) for the staged OverDrive integration.

The [capability and qualification ledger](docs/maintainers/capability-manifest.json) tracks implementation evidence, release status, platform limits and remaining gates. Code being present does not imply device qualification or a published download.

The [debrid, Stremio and remote-streaming guide](docs/plezyng/remote-streams/README.md) describes the implemented providers, shared playback and queue flows, architecture, native P2P status, and remaining validation limits.

The [Discord client and PiP feasibility plan](docs/plezyng/discord/README.md) preserves an optional future design, its research, architecture, and validation gates. It is deferred; no client implementation or delivery commitment is implied.

## Screenshots

Select any thumbnail to open the full-resolution image.

### Movies and TV · dark

<table>
  <tr>
    <td align="center" valign="top"><a href="docs/maintainers/store-listing-assets/amazon/tv-02-home-1920x1080.png"><img src="docs/maintainers/store-listing-assets/amazon/tv-02-home-1920x1080.png" alt="TV home with featured media and library rows" width="103" loading="lazy"></a><br><sub>TV home</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/store-listing-assets/amazon/tv-03-library-1920x1080.png"><img src="docs/maintainers/store-listing-assets/amazon/tv-03-library-1920x1080.png" alt="TV movie library and remote navigation" width="103" loading="lazy"></a><br><sub>TV library</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/store-listing-assets/amazon/tv-04-details-1920x1080.png"><img src="docs/maintainers/store-listing-assets/amazon/tv-04-details-1920x1080.png" alt="TV movie details and play action" width="103" loading="lazy"></a><br><sub>TV details</sub></td>
  </tr>
  <tr>
    <td align="center" valign="top"><a href="docs/maintainers/readme-captures/phone-dark-library.png"><img src="docs/maintainers/readme-captures/phone-dark-library.png" alt="Phone movie library browsing" width="56" loading="lazy"></a><br><sub>Phone library</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/readme-captures/tablet-dark-library.png"><img src="docs/maintainers/readme-captures/tablet-dark-library.png" alt="Tablet movie library with sidebar" width="103" loading="lazy"></a><br><sub>Tablet library</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/store-listing-assets/amazon/tv-01-welcome-1920x1080.png"><img src="docs/maintainers/store-listing-assets/amazon/tv-01-welcome-1920x1080.png" alt="TV welcome and source connection choices" width="103" loading="lazy"></a><br><sub>TV connections</sub></td>
  </tr>
  <tr>
    <td align="center" valign="top"><a href="docs/maintainers/readme-captures/phone-dark-welcome.png"><img src="docs/maintainers/readme-captures/phone-dark-welcome.png" alt="Phone welcome and connection choices" width="56" loading="lazy"></a><br><sub>Phone connections</sub></td>
  </tr>
</table>

### Playback and subtitles · dark / OLED

<table>
  <tr>
    <td align="center" valign="top"><a href="docs/maintainers/player-mockups/desktop-player-mockup-preview.png"><img src="docs/maintainers/player-mockups/desktop-player-mockup-preview.png" alt="Desktop playback controls" width="210" loading="lazy"></a><br><sub>Desktop playback</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/player-mockups/phone-player-mockup-preview.png"><img src="docs/maintainers/player-mockups/phone-player-mockup-preview.png" alt="Landscape phone playback controls" width="210" loading="lazy"></a><br><sub>Phone playback</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/readme-captures/tablet-dark-player-settings.png"><img src="docs/maintainers/readme-captures/tablet-dark-player-settings.png" alt="Android playback settings with player backend and buffering choices" width="210" loading="lazy"></a><br><sub>Playback settings</sub></td>
  </tr>
  <tr>
    <td align="center" valign="top"><a href="docs/maintainers/playback-appearance-previews/desktop-subtitle-style-dark-preview.png"><img src="docs/maintainers/playback-appearance-previews/desktop-subtitle-style-dark-preview.png" alt="Dark subtitle styling preview with size, position, colors and border controls" width="103" loading="lazy"></a><br><sub>Subtitle styling · dark</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/playback-appearance-previews/desktop-subtitle-style-oled-preview.png"><img src="docs/maintainers/playback-appearance-previews/desktop-subtitle-style-oled-preview.png" alt="OLED subtitle styling preview with font and background controls" width="103" loading="lazy"></a><br><sub>Subtitle styling · OLED</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/subtitle-ai-dark.png"><img src="docs/maintainers/feature-gallery/subtitle-ai-dark.png" alt="AI subtitles, transcription and translation tools" width="210" loading="lazy"></a><br><sub>AI subtitles</sub></td>
  </tr>
</table>

### Books and listening · dark

<table>
  <tr>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/ebook-reader-dark.png"><img src="docs/maintainers/feature-gallery/ebook-reader-dark.png" alt="EPUB reading with columns and reader tools" width="210" loading="lazy"></a><br><sub>EPUB · desktop</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/ebook-reader-phone-dark.png"><img src="docs/maintainers/feature-gallery/ebook-reader-phone-dark.png" alt="Phone EPUB reading" width="50" loading="lazy"></a><br><sub>EPUB · phone</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/ebook-reading-settings-dark.png"><img src="docs/maintainers/feature-gallery/ebook-reading-settings-dark.png" alt="Reading fonts, spacing and themes" width="103" loading="lazy"></a><br><sub>Reading preferences</sub></td>
  </tr>
  <tr>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/book-library-detail-dark.png"><img src="docs/maintainers/feature-gallery/book-library-detail-dark.png" alt="Book details with EPUB and audio editions" width="103" loading="lazy"></a><br><sub>Book editions</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/audiobook-player-dark.png"><img src="docs/maintainers/feature-gallery/audiobook-player-dark.png" alt="Audiobook chapters, speed and bookmarks" width="56" loading="lazy"></a><br><sub>Audiobook chapters</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/podcast-player-dark.png"><img src="docs/maintainers/feature-gallery/podcast-player-dark.png" alt="Podcast listening and chapter navigation" width="56" loading="lazy"></a><br><sub>Podcast chapters</sub></td>
  </tr>
  <tr>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/music-player-dark.png"><img src="docs/maintainers/feature-gallery/music-player-dark.png" alt="Music artwork, playback controls and queue" width="210" loading="lazy"></a><br><sub>Music and queue</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/visualizer-library-dark.png"><img src="docs/maintainers/feature-gallery/visualizer-library-dark.png" alt="Visualizer preset library and filters" width="210" loading="lazy"></a><br><sub>Visualizer presets</sub></td>
  </tr>
</table>

### Games · dark

<table>
  <tr>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/steam-library-dark.png"><img src="docs/maintainers/feature-gallery/steam-library-dark.png" alt="Steam library with installed games" width="210" loading="lazy"></a><br><sub>Steam library</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/steam-touch-game-dark.png"><img src="docs/maintainers/feature-gallery/steam-touch-game-dark.png" alt="Stardew Valley with touch controls" width="210" loading="lazy"></a><br><sub>Game and touch controls</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/steam-touch-layout-dark.png"><img src="docs/maintainers/feature-gallery/steam-touch-layout-dark.png" alt="Arrange touch controls" width="155" loading="lazy"></a><br><sub>Touch layout editor</sub></td>
  </tr>
  <tr>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/steam-controller-layout-dark.png"><img src="docs/maintainers/feature-gallery/steam-controller-layout-dark.png" alt="Gamepad controller layout" width="50" loading="lazy"></a><br><sub>Gamepad mappings</sub></td>
  </tr>
</table>

### Sources, discovery and workspace · dark

<table>
  <tr>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/connected-sources-dark.png"><img src="docs/maintainers/feature-gallery/connected-sources-dark.png" alt="Files, OPDS, audiobooks, NAS and cloud sources" width="150" loading="lazy"></a><br><sub>Files and cloud sources</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/open-media-dark.png"><img src="docs/maintainers/feature-gallery/open-media-dark.png" alt="Open a link, playlist or local media" width="56" loading="lazy"></a><br><sub>Open media</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/find-your-next-dark.png"><img src="docs/maintainers/feature-gallery/find-your-next-dark.png" alt="Find your next book or media pick" width="103" loading="lazy"></a><br><sub>Find your next</sub></td>
  </tr>
  <tr>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/multiview-dark.png"><img src="docs/maintainers/feature-gallery/multiview-dark.png" alt="Multiview workspace with reading and playback panes" width="210" loading="lazy"></a><br><sub>Multiview workspace</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/feature-gallery/live-tv-guide-dark.png"><img src="docs/maintainers/feature-gallery/live-tv-guide-dark.png" alt="Live TV channels and programme guide" width="103" loading="lazy"></a><br><sub>Live TV guide</sub></td>
  </tr>
</table>

### Appearance · dark / OLED / light

<table>
  <tr>
    <td align="center" valign="top"><a href="docs/maintainers/playback-appearance-previews/desktop-appearance-dark-preview.png"><img src="docs/maintainers/playback-appearance-previews/desktop-appearance-dark-preview.png" alt="Dark appearance preview" width="80" loading="lazy"></a><br><sub>Dark</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/playback-appearance-previews/desktop-appearance-oled-preview.png"><img src="docs/maintainers/playback-appearance-previews/desktop-appearance-oled-preview.png" alt="OLED appearance preview" width="80" loading="lazy"></a><br><sub>OLED</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/playback-appearance-previews/desktop-appearance-light-preview.png"><img src="docs/maintainers/playback-appearance-previews/desktop-appearance-light-preview.png" alt="Light appearance is also available" width="44" loading="lazy"></a><br><sub>Light</sub></td>
  </tr>
</table>

<details>
<summary>More light-mode layouts</summary>

<table>
  <tr>
    <td align="center" valign="top"><a href="docs/maintainers/store-listing-assets/google-play/phone-01-welcome-1080x1920.png"><img src="docs/maintainers/store-listing-assets/google-play/phone-01-welcome-1080x1920.png" alt="Light phone welcome" width="56" loading="lazy"></a><br><sub>Phone connections</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/store-listing-assets/google-play/phone-03-library-browse-1080x1920.png"><img src="docs/maintainers/store-listing-assets/google-play/phone-03-library-browse-1080x1920.png" alt="Light phone library" width="56" loading="lazy"></a><br><sub>Phone library</sub></td>
    <td align="center" valign="top"><a href="docs/maintainers/store-listing-assets/google-play/tablet-01-library-2560x1600.png"><img src="docs/maintainers/store-listing-assets/google-play/tablet-01-library-2560x1600.png" alt="Light tablet library" width="103" loading="lazy"></a><br><sub>Tablet library</sub></td>
  </tr>
</table>

</details>

[Image credits](docs/maintainers/feature-gallery/README.md#image-credits) · [Playback image credits](docs/maintainers/player-mockups/ATTRIBUTION.md)

## Dolby Vision experiments

Pleazyng has developed genuine Profile 7 FEL reconstruction alongside native and
compatibility playback. The isolated Linux engine has rendered the FEL mark in a
real P7 sample through standalone mpv and embedded libmpv; full app playback and
independent reference-pixel accuracy still need qualification. Linux users can
opt in under **Settings → Playback**, with a separate compatibility fallback and
video experiment logging switch. A separate engine build is required.

An experimental Android AAR now passes a synthetic FEL-on versus explicit
EL-dropped pixel comparison through mpv's real `gpu-next` Surface output on an
API 36 x86_64 emulator.

The repository also includes a pinned Apple dual-layer experiment host for
macOS/iOS/tvOS, an offline FEL-to-HDR/SDR companion pipeline, and platform testing
instructions. These are experimental paths, not a claim of universal or certified
Dolby Vision support. P7→P8.1 compatibility discards EL and is labelled separately.
Cross-platform playback and native Dolby Vision output are qualified separately;
native Dolby Vision signaling depends on the platform and connected display path.
See the [buildout, setup and Luna handoff](docs/maintainers/dv-platform-buildout.md)
and [Linux engine evidence](docs/maintainers/dv-engine-luna-handoff.md).

## What Pleazyng has built

Pleazyng builds on upstream Plezy with a broad set of features for Plex, Jellyfin, and Emby, wherever each server's APIs allow. The table below highlights delivered code, links related upstream work for context, and notes platform or server limitations. An implementation entry describes code presence; it does not imply live-server or device qualification unless that evidence is stated.

| Area | Related upstream work | Pleazyng status |
| --- | --- | --- |
| Downloads | Converted download quality; per-rule quality; auto-download Continue Watching items and remove them when they leave the shelf (#1145, #1413, #1847, #1978, #2181, #2206) | Code is implemented for Plex, Jellyfin, and Emby; validation against real servers remains pending. Jellyfin and Emby use progressive transcodes that restart after an interrupted transfer. |
| Downloads | Local Plex connections (#1447/#2248); download size and storage usage (#2376); manual sync and random episode selection (#1197, #1199) | Implemented in Pleazyng |
| Downloads | Playlist downloads and watched-item cleanup (#1721, #2600, #1413, #2181); orphan cleanup | Playlist downloads and watched-item cleanup are implemented. The Downloads screen can review and remove orphaned tagged files in the default app-managed folders; custom/SAF roots, legacy files, shared artwork, and iOS Documents are left untouched. |
| Profiles and privacy | PIN-gate download deletion, settings, and Explore; hide Explore per profile (#1924, #2514) | Local profile PIN gates Settings, download deletion, and entry to Explore; Explore can also be hidden per profile. Plex Home PINs remain server-owned. |
| Audio and subtitles | Remember choices per show; choose tracks before playback; always-on subtitles and preferred-language fetching; per-item sync offsets (#84, #1758, #1956, #2116, #2182, #2346, #2382, #2792) | Code implements per-show memory, optional pre-play selection, device-local preferred-language selection and opt-in provider downloads, and scoped sync offsets across Plex, Jellyfin, and Emby. Per-show choices are app-profile local; real-server validation remains pending. Explicit server-selected tracks, account Off, and local picks remain authoritative. |
| Files and books | Standalone file sources, metadata, subtitles, ebooks and audiobooks | SMB2/3, optional encrypted NFSv3 RPC-with-TLS, FTP-family, SFTP, DLNA, Komga, WebDAV, S3, OPDS, cloud drives and Audiobookshelf; local Kodi/Jellyfin NFO/posters, confidence-gated Trakt metadata/cast/artwork/trailers, and OpenSubtitles search (including SMB; file-hash matching when an exact local or cached copy is available); EPUB/PDF/CBZ, multipart audiobook playback and progress sync through app-owned state files. Cloud sync never uploads or edits playback media. Availability varies by platform; see the [setup guide](docs/FILES_AND_BOOKS.md) for limits and security. |
| Universal media tools | Direct media URLs, radio playlists, local files, capture, sharing, extensions, Wi-Fi transfer, conversion, recording and picture controls | **Open media** handles session-only HTTP(S)/MPV streams, M3U/PLS/HLS playlists, temporary file and desktop folder queues, and supported ISO/disc inputs; the active source player offers queue browsing, upcoming-file shuffle, repeat, and item selection in one adaptive sheet. Eligible desktop queues can be saved as sibling-relative M3U files in current playback order. MPV exposes direct-input File Info and edition/disc-title choices when available. Safe stream favorites are profile-local. Desktop tools add screen/camera recording and live preview, temporary private-LAN HLS sharing, declarative HTTPS search extensions, `plezyctl` (Python 3.10+), FFmpeg conversion and MPV live-stream recording. See the [Open media guide](docs/UNIVERSAL_MEDIA.md) and [VLC feature comparison](docs/VLC_FEATURE_PARITY.md) for privacy and platform limits. |
| Cloud and add-on streaming | — | Real-Debrid/AllDebrid QR or PIN connection, Premiumize/TorBox API-key validation, on-demand cloud-file browsing through Files and books, cached cloud-video Search and Home posters, Stremio QR account linking with a selectable add-on import preview, and manual HTTPS add-on setup. Supported add-on catalogs appear in Explore; stream options open from existing title details. Matched server items use the shared video player and queue, with resume updates reconciled through the local watch queue. Credentials are encrypted and profile-scoped. Native peer-to-peer playback and canonical cloud/server library-card merging are implemented; live provider and packaged-device qualification remain open. Matched external playback reports active sessions through its owning server; live server acceptance remains pending. See the [connected streaming guide](docs/plezyng/remote-streams/README.md). |
| Subtitle controls | Live styling preview (#2347); in-player size and position controls (#95, #689, #2174); load a local subtitle file (#1431) | Local/archive import, dual-track controls, exact and cue-based sync, drift preview/undo, cue navigation/replay, and corrected export are implemented. Local AI workflows add WAV-based speech recognition, translation, automatic timing/cut repair, bilingual review, revision history and server attachment. Live capture, model availability and acceleration depend on the player and packaged runtime; device qualification remains open. See [Subtitles and local AI](#subtitles-and-local-ai). |
| Playback | Swipe-to-seek (#2601), frame stepping (#1584), subtitle-delay hotkeys (#2824), remembered version across episodes (#2563), video playlist repeat (#1757/#1985) | Implemented in Pleazyng |
| Playback | Plex cinema pre-rolls (#970/#2483); random local pre-rolls (#2271); theme music (#791/#2170/#2596) | Server-configured cinema intro code is present for Plex, Jellyfin, and Emby; real-server validation remains pending. Local pre-rolls, detail-page theme songs, and home spotlight music are implemented in the app. |
| Playback | Background video/audio-only mode (#367), mpv equalizer (#2292), local/remote quality presets (#2064), opt-in TheIntroDB fallback (#389, #1110, #1886) | Optional audio-only background playback is implemented on handheld Android and iOS; Android uses the OS media playback service. A ten-band device-local equalizer plus MPV stereo widening, room ambience, and pitch shift are available where the build and track support them; opt-in intro fallback is implemented. |
| Browsing | Director links (#2762), library item counts (#1516), Watchlist filters (#2725), MDBList Explore lists (#2740), Seerr search results (#2811) | Implemented in Pleazyng |
| Browsing | Search by actor or director (#1517, #2368); random movie or library shuffle (#1561, #2741, #2757); show end time on detail pages (#2671) | People search, random movie selection, and shuffled playback of movie and TV libraries are implemented across connected servers; detail-page finish time is shown on media details |
| Home screen | Configurable rows, merged library and collection rows, organizer controls, and Plex account layout sync (#1652/#2203) | Implemented; Plex account sync applies to Plex profiles. Custom rows can combine selected libraries across connected servers |
| Home screen | Separate Next Up; hide empty libraries or backdrop art; Continue Watching row sizing (#2498, #2690, #2701, #2723, #2784) | Continue Watching and Next Up have separate Home rows and independent visibility/order. Empty-library filtering hides a library only when its server reports an explicit count of zero; unknown counts remain visible. Backdrop visibility and row sizing are implemented. The legacy hero banner visibility setting and TV clock already exist. |
| Servers and links | Preferred server (#591, #1529, #2720); `plezy://watch` links (#2681); return from external players with synced progress (#2738) | Preferred server is stored per profile and moves first in aggregate queries across Plex, Jellyfin, and Emby; watch links and external-player return sync are implemented |
| Live TV | Timeshift timeline (#2300) | Plex implementation is in the fork; Jellyfin/Emby DVR-window support remains under investigation because their public playback APIs do not expose the tuner's seekable capture window |
| Integrations | Google Cast (#126); new-episode notifications (#1146); content screensaver (#401) | Google Cast handoff code is implemented on Android and iOS through the default media receiver; receiver codec/container support and server reachability are required, and physical-receiver validation remains pending. Profile-scoped episode alerts poll connected Plex, Jellyfin, and Emby libraries while the app is foregrounded; Android/iOS device validation remains pending, and alerts do not have a background push source. The screensaver rotates artwork from selected connected libraries after an idle timeout. |
| Automation | Home Assistant control and Android automation intents (#823, #1996) | Android `ACTION_VIEW` links can open cross-server `plezy://watch` media, select an existing profile with `plezy://profile?id=…`, and control the active video session with `plezy://control` commands `play`, `pause`, `toggle`, or `stop`. Home Assistant can invoke these through an Android intent bridge; this does not expose Plezy as a native Plex Companion player in Home Assistant. See the [Android automation guide](docs/plezyng/android-automation.md). |
| Settings and diagnostics | Save logs to a file (#2496); cloud settings backup (#1795) | Log export is implemented; cloud settings backup uploads and restores only the portable settings JSON through an HTTPS WebDAV file endpoint. Server credentials, playback history and media files stay on their existing paths. |
| Cross-media discovery | — | Find your next combines media from configured sources with Saved picks, history/undo, comparison, local taste controls and co-present shortlist voting. Optional AI reranking and encrypted Saved-pick sync are opt-in; see the [delivery record](docs/plezyng/swipe/DELIVERY.md). |
| Listening and reading | — | Dedicated podcast discovery/subscriptions, OpenSubsonic music, EPUB/PDF/CBZ readers, Komga comics, Audiobookshelf and Hardcover shelf/progress integration extend the server libraries. See [Files, books and listening](docs/FILES_AND_BOOKS.md). |
| Games and media workspace | — | Experimental embedded GameStream/Steam receivers and an app-owned Multiview workspace are present in source. Native composition, simultaneous decoding, host sessions and device qualification remain platform-specific gates; see [Games](docs/games/ARCHITECTURE.md) and [Multiview](docs/plezyng/multiview/DELIVERY.md). |
| Playback experiments | — | Opt-in Neural motion processing, native projectM/MilkRust preset visualizers and Dolby Vision FEL work have separate runtime and qualification requirements. See [Experimental playback and workspace](#experimental-playback-and-workspace). |

This table is a snapshot of downstream work and its current limits. The linked upstream requests provide context for the gap Pleazyng addresses; equivalent upstream implementations can replace the corresponding downstream code when their behavior and server coverage match.

<p>
  <a href="https://plezyng.app/">Website</a> ·
  <a href="https://github.com/edde746/plezy">Upstream Plezy</a> ·
  <a href="https://github.com/snapetech-org/PlezyNG/issues">Pleazyng issues</a> ·
  <a href="#download">Download</a> ·
  <a href="CONTRIBUTING.md">Contributing</a> ·
  <a href="LICENSE">License</a>
</p>

<p align="center">
  <img src="assets/branding/pleazyng-artwork-dark.webp" alt="Pleazyng by SnapeTech — brand illustration" width="900" />
</p>

## Download

[Pleazyng 3.0.5 is published](https://github.com/snapetech-org/PlezyNG/releases/tag/v3.0.5) with Android, Fire TV, Linux x64/ARM64, Windows x64/ARM64, universal macOS, iOS, tvOS, Tizen and webOS packages. See the [recorded GitHub publication evidence](docs/maintainers/releases/v3.0.5.json) and [all releases](https://github.com/snapetech-org/PlezyNG/releases).

| Platform | Download |
| --- | --- |
| Desktop and mobile | [Release files for Android, Fire TV, Linux, Windows, macOS, iOS and tvOS](https://github.com/snapetech-org/PlezyNG/releases/tag/v3.0.5) |
| webOS TV | [Experimental ARMv7 IPK](https://github.com/snapetech-org/PlezyNG/releases/tag/v3.0.5); model/firmware and media playback qualification remain separate from publication. See the [compatibility matrix and port status](docs/maintainers/webos-tv.md). |
| Samsung Tizen TV | [Experimental ARM tester handoff](https://github.com/snapetech-org/PlezyNG/releases/tag/v3.0.5); TV qualification and Tizen 10 remain pending. See the [build guide and rollout plan](docs/maintainers/tizen-tv.md). |

<details>
<summary>Install with a package manager</summary>

### macOS — Homebrew

The `snapetech-plezyng` Cask is being prepared. It will be installable after a signed and notarized macOS release is published and the generated Cask is added to this repository.

```bash
# After the Cask is published in this tap
brew tap snapetech-org/PlezyNG https://github.com/snapetech-org/PlezyNG
brew install --cask snapetech-plezyng
```

### Linux — Flatpak

Install Flatpak with your distribution's package manager, download the bundle for your architecture above, then run:

```bash
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user flathub org.freedesktop.Platform//25.08
flatpak install --user ./plezy-linux-x64.flatpak
flatpak run org.snapetech.plezyng
```

On arm64, install `plezy-linux-arm64.flatpak`.

<details>
<summary>Sandbox, playback, and folder access</summary>

- Not on Flathub — the remote supplies the Freedesktop runtime only.
- Video playback needs a Wayland session; a pure X11 session shows the interface but cannot create the video plane.
- No host or home filesystem access; app data lives in `~/.var/app/com.edde746.plezy/`. Add host folders through the desktop file chooser portal, and keep download folders writable.
- Network, display, audio, and device access are enabled. `--device=all` (Flatpak 1.14 compatibility) exposes more than GPUs and controllers; session-bus access stays filtered.

</details>

The following distribution packages are for upstream **Plezy**, not this Pleazyng fork. Use the Pleazyng release bundles above for the features documented here.

### Arch Linux — Pacman (upstream Plezy)

[Distribution package](https://archlinux.org/packages/extra/x86_64/plezy/).

```bash
sudo pacman -S plezy
```

### Fedora / Red Hat — DNF

[Installation instructions](https://github.com/aldobarr/plezy-rpm) · Community repository by [@aldobarr](https://github.com/aldobarr).

### Nix

[Community package](https://search.nixos.org/packages?channel=unstable&query=plezy) maintained by [@mio-19](https://github.com/mio-19) and [@MiniHarinn](https://github.com/MiniHarinn).

### aerynOS — Moss

[Distribution package](https://github.com/aerynOS/recipes/tree/main/p/plezy).

```bash
sudo moss pad plezy
```

</details>

## Android closed beta

Pleazyng's Google Play closed test is being prepared. Once the test release is published, invited testers can opt in at [the Pleazyng Google Play test page](https://play.google.com/apps/testing/org.snapetech.plezyng). The link is inactive until then, and only accounts added to the test can join. Google Play requires at least 12 testers to stay opted in continuously for 14 days before production access.

## Features

This list covers the current Pleazyng codebase, including additions since the fork. Server APIs, build options and native runtimes determine availability. Experimental and gated features are identified below; implementation does not by itself establish a published package or device qualification.

### <img src="assets/readme_icons/browse.svg" height="20" alt="" align="center" /> Browse & Discover

- Libraries, collections, and playlists — video and audio
- Shuffle a whole movie or TV library
- Discover hub — Continue Watching, Next Up, trending, and recommendations
- Configurable Home rows: merge Recently Added / Recently Released across whichever libraries you pick, or a collections row scoped to specific libraries or collections
- Hide Home backdrop artwork and choose compact, standard, or large Continue Watching cards
- Cross-server search across connected Plex, Jellyfin, and Emby libraries, including actors and directors
- Unified Search also includes indexed Files and books, connected catalogs and Seerr; exact catalog IDs suppress duplicate server/catalog results
- Continue Watching shows a title held in several libraries or on several servers once, and asks which copy to play
- Filtering, sorting, and alphabetical jump navigation
- Folder browsing and folder playback — home-video libraries open in folder view
- Resolution, HDR/Dolby Vision, and audio-format badges on cards and detail pages
- Favorites and unwatched library filters[^mb]
- Extras — trailers, deleted scenes, behind-the-scenes
- Genre browsing, bulk watch-state actions, and library/collection/playlist controls

### Find your next

- A cross-media discovery deck for video, music, books, comics, audiobooks and live programs, with touch, keyboard, D-pad and gamepad controls
- Source, genre, mood, familiarity and available/offline filters; explicit preferred/avoided genres and per-pick hide, restore and taste reset
- Profile-local Saved picks, review history, undo/retry, two- or three-pick comparison, and private pass-the-device shortlist voting
- Bounded OPDS sample previews, exact-ID adaptation links, and browse-only Open Library candidates
- Optional AI reranking through a user-configured endpoint, with ordinary ranking as fallback; optional encrypted Saved-pick sync
- See the [discovery guide and delivery limits](docs/plezyng/swipe/README.md); borrower-catalog candidates require the separately gated lending integration

### <img src="assets/readme_icons/explore.svg" height="20" alt="" align="center" /> Explore & Requests

- Explore tab — watchlist, trending, popular, and recommendation rows from Plex Discover[^plex], Trakt, MyAnimeList, AniList, Simkl, and Seerr[^connect]
- Search any connected catalog source
- Catalog titles matched back to your own libraries by external ID
- Seerr — request movies and shows with per-season, 4K, and advanced destination options, and see request status inline
- Watchlist sync — add and remove titles on Plex, Trakt, MyAnimeList, AniList, and Simkl from anywhere in the app
- Custom MDBList Explore lists and a searchable, region-aware directory of official provider/storefront destinations

### Files, books, comics & audiobooks

- Start with a local profile and use Files and books without a Plex, Jellyfin or Emby account
- Local imports and desktop folders; SMB2/3, NFSv3 with optional RPC-with-TLS, FTP/FTPES/FTPS, SFTP, DLNA/UPnP, WebDAV/Nextcloud and S3-compatible sources
- Google Drive, OneDrive and Dropbox file browsing; OPDS 1/2 catalogs, Komga libraries and Audiobookshelf
- Video shelves with offline Kodi/Jellyfin NFO/poster sidecars, opt-in Trakt metadata/cast/artwork/trailer matching, and OpenSubtitles lookup
- EPUB reading with contents, search, highlights, notes, resume and authored media-overlay read-along; PDF search, outlines, notes and pinch/pan
- CBZ and Komga comics with one/two-page spreads, LTR/RTL direction, wide-page splitting, continuous scrolling, thumbnails and zoom
- Reader font, spacing, margins, columns, colour and scrolling preferences; platform text-to-speech where available
- Multipart audiobooks with reviewed file ordering, chapters, bookmarks, speed, sleep timer, background controls and resume
- Optional encrypted reading/listening progress and annotation sync through supported cloud storage; concurrent positions remain an explicit choice
- Hardcover shelf import, exact-edition matching and preview/undo for shelf and reading-progress updates
- Public catalog browsing through Open Library and Google Books, plus edition-aware official bookstore and comic-storefront handoffs
- See [Files, books and listening](docs/FILES_AND_BOOKS.md). Document reading is unavailable on TV; Linux EPUB/CBZ opens in the system browser. OverDrive lending remains [disabled pending provider approval and qualification](docs/LENDING_SETUP.md).

### Cloud & add-on streaming

- Profile-scoped Real-Debrid, AllDebrid, Premiumize and TorBox connections, cloud-file browsing and indexed Search/Home entries
- Stremio account linking with an add-on import preview, manual HTTPS add-ons, Explore catalogs, episode browsing and stream selection
- Shared video player, previous/next queues, subtitles, resume and renewable links for supported cloud/add-on streams
- Exact-identity cloud/server library-card merging and server-copy choices; unmatched streams retain source-local progress
- Durable preparation jobs with cancellation, retry and recovery; eligible files use the existing Downloads queue
- Optional native libtorrent peer-to-peer streaming requires a compatible packaged runtime
- See the [remote-streaming guide](docs/plezyng/remote-streams/README.md). Live-provider and packaged-device qualification remain open; matched external streams now report active sessions through their owning server, with live server acceptance pending.

### <img src="assets/readme_icons/playback.svg" height="20" alt="" align="center" /> Playback

- Wide codec support (HEVC, AV1, VP9, and more)
- HDR and Dolby Vision[^hdr]
- Direct play, or transcode presets from 240p/320 kbps to 1080p/20 Mbps
- Multi-version switching with per-version file details
- Full ASS/SSA subtitles with customizable styling
- Optional TheIntroDB intro timings when Plex, Jellyfin, or Emby has no intro marker; disabled by default
- Online subtitle search and download where supported by the server or configured OpenSubtitles source
- Audio and subtitle track selection with server-provided defaults
- Optional pre-play track selection, remembered per-show audio/subtitle choices, ordered preferred languages and scoped sync offsets
- MPV alternate video-track selection when a source exposes multiple video streams
- Progress sync and resume
- Auto-play next episode with skip intro / skip credits
- Server cinema intros, random local pre-rolls, detail-page theme songs and Home spotlight music where supported
- Frame stepping, swipe seeking, subtitle-delay shortcuts and remembered version choices across episodes
- Optional audio-only continuation when the app backgrounds on Android and iOS
- Chapter navigation with thumbnail scrub previews
- Playback speed from 0.25x to 8x, audio sync offset, sleep timer (fixed durations or end of video)
- Video zoom 50-200% with pinch, presets, and hotkeys
- Audio passthrough[^pass], output channel limit (5.1 or stereo, with center-channel boost), and loudness normalization
- Ten-band device-local equalizer plus MPV stereo widening, room ambience and pitch shift; active filters decode audio and turn passthrough off
- Named device-local playback bookmarks for server media and Open media audio/video, plus temporary MPV A/B segment looping in existing playback controls
- File Info sheet — every version, file, and stream the server reports
- Ambient lighting and GLSL shader presets[^mpv]
- Picture-in-Picture[^pip]
- Refresh-rate matching[^rrm]
- Motion & clarity — motion presets, temporal blending, motion-compensated frame generation, OLED and sports profiles, generated-rate and search controls, desktop player-bar toggle with hold-to-open presets, mobile Video settings access, live A/B comparison, and scoped preferences[^mpv]. See the [Motion & clarity guide](docs/plezyng/motion-clarity/guide.md).
- External player launch (VLC, MX Player, etc.) with progress sync back[^android]
- **Open media** — session-only HTTP(S) streams, HLS and M3U/PLS playlists (including safe same-folder local entries), profile-local safe favorites, temporary local file and desktop folder queues, desktop same-folder M3U export, direct MPV File Info, and edition/disc-title choices when exposed by the input
- Advanced RTSP/RTMP/RTMPS/UDP/RTP inputs, opt-in unencrypted FTP streams, optical-disc/ISO playback, and Wi-Fi file transfer on supported builds
- MPV picture adjustments and optional 360° flat view; desktop MPV live-stream recording
- Desktop screen/camera recording with optional audio or live preview in the MPV player, plus temporary HLS sharing over a private IPv4 network
- Data-only HTTPS search extensions and the `tools/plezyctl` CLI, with results handed to the existing Open media form
- Desktop local conversion/remux to MP4/MKV, M4A, MP3, FLAC, WAV, Ogg Opus, or WebM when the user-installed FFmpeg has the required encoders and output containers
- Direct HTTP(S) playback uses a session-owned loopback gateway; recognized credential/signature parameters cannot be saved. Platform boundaries and transfer limits are in the [Open media guide](docs/UNIVERSAL_MEDIA.md).

### Subtitles and local AI

- In-player style preview, size/position/colour controls, primary and secondary subtitles, SDH/CC and generated/translated track labels
- Exact millisecond offsets, separate secondary delay, cue alignment, two-anchor drift calibration, temporary preview and undo on supported MPV text paths
- Local subtitle import, desktop drop and Android share; bounded ZIP, TAR and gzip-TAR archives, including supported paired IDX/SUB files
- Cue copy, previous/next navigation, replay with preroll, and corrected SRT/WebVTT/simple ASS export where supported
- Local WAV-based speech recognition and translation, same- and cross-language timing synchronization, and automatic drift/cut repair
- Editable bilingual review, terminology/glossary warnings, provenance, device-local revision history, restore/undo, SRT/versioned JSON export and supported server attachment
- Captured-transcript search, cue seeking and optional hide-future-dialogue filtering on the Android ExoPlayer path
- Live captions/capture and model acceleration are capability-gated. MPV paths need matching native capture extensions; webOS requires supplied audio. Hardware placement, sustained performance and device behavior remain unqualified. See the [subtitle implementation](docs/plezyng/subtitles/PLAN.md) and [qualification matrix](docs/plezyng/subtitles/QUALIFICATION.md).

### <img src="assets/readme_icons/music.svg" height="20" alt="" align="center" /> Music

- Music libraries — artist, album, and track browsing with square artwork
- Album and artist screens with play, shuffle, and Instant Mix
- Gapless playback with a full play queue — reorder, remove, play next, add to queue
- Now Playing with synced lyrics[^lyrics], persistent mini-player, and sleep timer
- Accessible visualizer that follows Plex analysis or optional live audio stats on compatible MPV builds
- Background playback with lock-screen, media-key, and notification controls[^bgaudio]
- Offline playback of downloaded albums and tracks
- Streaming quality presets — Original, 320, 192, or 128 kbps
- OpenSubsonic/Subsonic artist, album, track and recent-album browsing, search and shared-player playback; progress is profile-local, with optional WebDAV state sync
- Visualizer preset library with offline starter pack, local preset/texture-pack imports, search, favorites, playlists, shuffle, lock and fullscreen controls. Native projectM/MilkRust rendering is experimental and needs matching engine/PCM dependencies; see the [visualizer guide](docs/plezyng/visualizations/USER_GUIDE.md).

### Podcasts

- Dedicated Podcasts hub for subscriptions, latest episodes, search, listening status, ordering and verified-offline filters
- Apple Podcasts directory discovery without an account, optional Podcast Index search/trending with personal credentials, and direct public/private RSS or Atom feeds
- OPML subscription import/export with explicit confirmation before exporting private feed links
- Audio/video enclosures, show notes, publication/season/episode metadata, Podlove and Podcasting 2.0 chapters
- Audiobookshelf podcast shows and episode-specific playback/progress; shared-player resume, speed, sleep timer, bookmarks and manual offline downloads
- Per-show automatic downloads and retention, archive pagination, transcript search/seek and opt-in gpodder synchronization are implemented in source. See the [podcast implementation and limits](docs/plezyng/podcasts/IMPLEMENTATION.md) for protocol and device qualification limits
- Dedicated karaoke host/songbook, singer rotation, open rendition packages, timed lyrics/CD+G, practice and optional microphone/private-take workflows are integrated in source. Licensed catalogs, hosted sharing and native microphone monitoring remain open; see the [karaoke ledger](docs/plezyng/karaoke/PLAN.md)

### <img src="assets/readme_icons/live-tv.svg" height="20" alt="" align="center" /> Live TV & DVR

- Live TV channel browsing, tuning, and favorites
- EPG guide with What's On and per-show schedules
- DVR recording rules, scheduled recordings, and a rememberable recording target library[^plex]
- Multi-server Live TV support where available
- Plex timeshift timeline; Jellyfin/Emby DVR-window seeking depends on server API support
- Profile-owned IPTV setup for M3U/XMLTV, Xtream, Tunerr, Dispatcharr and optional Stalker/Ministra portals, plus supported VOD, local timeshift and recording paths. Provider credentials, backend behavior and device acceptance remain separate requirements; see the [IPTV plan and delivery tracker](docs/plezyng/iptv/PLAN.md).

### <img src="assets/readme_icons/downloads.svg" height="20" alt="" align="center" /> Downloads & Offline

- Download movies, shows, and music for offline playback[^dl]
- Background queue with pause / resume
- Sync rules for automatic downloads, with per-show "Include Specials"
- Per-rule download quality, plus automatic Continue Watching downloads with cleanup when an item leaves the shelf
- Converted video downloads for Plex, Jellyfin, and Emby; progressive server transcodes may restart after an interrupted transfer
- Optional per-item quality prompt, playlist downloads, manual Sync now, custom quantities and random episode selection
- Offline browsing with watch state sync-back on reconnect
- Local profile PIN gates for Settings and download deletion; per-profile Explore visibility
- Storage and per-item size reporting, watched-item cleanup, and review/removal of orphaned tagged files in app-managed folders
- Offline source books, comics, audio and video with complete-file checks; interrupted source playback preserves resume and offers retry

### <img src="assets/readme_icons/watch-together.svg" height="20" alt="" align="center" /> Watch Together

- Rooms on [Open Watch Party](https://openwatch.party) — share a six-character code; friends join from Plezy or another Open Watch Party app
- Everyone plays their own copy from their own server — Plex, Jellyfin, or Emby — matched by catalogue IDs, with a picker when several copies fit
- Synchronized play / pause / seek, host or shared control, room lock, and host handoff
- Public relays by default, or point Plezy at your own self-hosted relay
- Recent rooms, reconnect/readiness states, media-mismatch handling, per-user offsets and supported online-backed downloads

### Games & home streaming

- Optional profile-scoped Games library with paired computers, favorites, recent games, LAN discovery, manual addresses and explicit Wake-on-LAN
- Embedded Android Moonlight/GameStream engine for compatible hosts, with PIN pairing, certificate trust, host application lists and touch/controller input
- Experimental Steam receivers in Android, Linux, Windows and Apple source, with secure pairing, H.264/HEVC/HDR paths, surround preferences, controller feedback, editable touch layouts, explicit microphone sharing and connection diagnostics. Internet relay and Cloud/Family actions require their configured services and live acceptance checks
- RomM catalog, exact-copy selection, in-app browser/stream/native play routes, offline files and durable save synchronization are integrated in source; native cores and signing remain platform build inputs. See the [RomM integration](docs/games/ROMM_INTEGRATION.md)
- Supported Steam quality/audio preferences, reconnect controls, account-linked reference catalogs and host-bound game activity
- Separately permissioned Companion Remote game-session and host actions
- See the [Games architecture](docs/games/ARCHITECTURE.md) and [validation record](docs/games/VALIDATION.md). Native build coverage and real host/controller/device qualification vary by platform; HDR and automatic internet traversal are unfinished.

### Experimental playback and workspace

- **Neural motion processing:** opt-in desktop PME, Android LiteRT/QNN and Apple paths, on-demand verified model packs with progress, live Performance/Balanced/Quality switching where supported, capability diagnostics and smoothing/normal-playback fallbacks. Real-time device and presentation qualification remains separate; see [motion processing](docs/plezyng/motion-processing.md).
- **Dolby Vision FEL:** separate Linux reconstruction engine, Android synthetic experiment, Apple dual-layer host and offline FEL-to-HDR/SDR pipeline. These require experimental builds and platform/display qualification; see [Dolby Vision experiments](#dolby-vision-experiments).
- **Multiview:** app-owned floating/side-by-side media workspace with session tray, move/resize/return controls, separate audio/input ownership and capability-gated video, reading, music and Steam surfaces. Concurrent decoding, native composition and platform/device acceptance remain open; desktop detached windows are unfinished. See the [workspace delivery record](docs/plezyng/multiview/DELIVERY.md).
- Native preset visualization has its own [runtime requirements](docs/plezyng/visualizations/USER_GUIDE.md); provider-gated lending, Watchmode availability and the Apple MusicKit pilot retain their separate activation requirements. The optional full Discord client remains a deferred design.

### <img src="assets/readme_icons/integrations.svg" height="20" alt="" align="center" /> Integrations

- Discord Rich Presence[^desktop]
- Trakt, MyAnimeList, AniList, and Simkl — ratings, watched sync, and real-time scrobbling[^rt]
- Scores from connected trackers on detail pages — Trakt, Simkl, MyAnimeList, and AniList, plus Rotten Tomatoes, Metacritic, Letterboxd, IMDb, and TMDB through MDBList
- Plezy Remote — control desktop and TV from mobile
- Google Cast handoff on Android/iOS; receiver codecs and server reachability determine playback
- Previewed Trakt movie-history CSV export for manual Letterboxd import, including rewatches
- Official storefront/rental handoffs, commercially gated Watchmode availability, and an iOS-only Apple MusicKit pilot behind a build flag; see the [integration status and activation gates](docs/plezyng/service-integrations/README.md)
- Watch Next row and tvOS Top Shelf[^shelf]
- Android automation links for media launch, active-video controls, and profile selection
- [`plezy://` links](#plezy-links) to open a profile, play a title, or tune a channel from Home Assistant, launchers, or an NFC tag; any movie, show, or episode menu shows its link[^links]

### <img src="assets/readme_icons/customization.svg" height="20" alt="" align="center" /> Platform & Customization

- Desktop, mobile, and TV — full D-pad, keyboard, and gamepad support
- Multiple servers at once — Plex, Jellyfin, and Emby side by side
- Profiles with per-profile downloads, watch state, and settings; Plex Home switching with PIN
- Jellyfin and Emby local-server discovery and multiple URLs per server; Quick Connect sign-in[^jf]
- TV layout options — corner spotlight backdrop, full-card artwork, and Force TV mode on desktop
- Customizable keyboard shortcuts[^desktop]
- Metadata and artwork editing
- Settings import/export
- Optional HTTPS WebDAV backup/restore of portable settings; credentials and media are excluded
- Preferred server per profile, direct Plex-server sign-in, and connector hub for servers, file sources and service handoffs
- Foreground new-episode polling alerts and an idle artwork screensaver from selected libraries
- Shared accessibility preferences, scalable layouts, reduced motion, screen-reader labels and RTL/input navigation
- Household readiness checks, diagnostic log export and QR support flow with a reviewable issue draft and optional redacted logs
- Localized across 37 locale choices
- Experimental LG webOS and Samsung Tizen ports, with separate firmware/device qualification limits in the [download table](#download)

[^jf]: Jellyfin only.
[^mb]: Jellyfin and Emby only.
[^plex]: Plex only.
[^connect]: Requires connecting the service under Settings > Services.
[^hdr]: In-app HDR toggle on Windows, macOS, iOS, tvOS, and Linux — Linux needs a colour-managed Wayland compositor. Dolby Vision on Android, macOS, and Apple TV.
[^pass]: Desktop, Android TV, and Apple TV.
[^mpv]: Requires mpv's GPU renderer — unavailable on iOS, tvOS, and macOS, and Android defaults to ExoPlayer.
[^pip]: Android, iOS, and macOS — not on Android TV or Apple TV.
[^rrm]: Windows, Android, tvOS, and fullscreen macOS playback where supported by the active display.
[^android]: Progress sync on Android.
[^lyrics]: Where your server provides lyrics.
[^bgaudio]: tvOS pauses music when the app is backgrounded.
[^dl]: Not available on tvOS.
[^desktop]: Desktop only.
[^rt]: Real-time scrobbling on Trakt and Simkl; MyAnimeList and AniList update on completion.
[^shelf]: Android TV / Fire TV and tvOS.
[^links]: Android, iOS, macOS, and tvOS.

## plezy:// links

Pleazyng accepts both `plezy://` and `plezxyng://` schemes; links shown by the app continue using `plezy://` for compatibility. Use either scheme with the hosts and parameters below. Links start Plezy from outside the app. Any link may add `profile=<profile>`: a profile id, a Plex Home user UUID, or a display name (ignoring case; it must match one profile). Plezy switches to that profile first, and a protected profile still asks for its PIN. A link replaces whatever is playing.

| Link | Does |
|---|---|
| `plezy://open` | Opens Plezy |
| `plezy://play?server=<server>&id=<item>` | Plays one item on one server, any backend |
| `plezy://play?type=movie\|show&tmdb=<n>` | Plays a title from whichever server has it. Use `tmdb`, `tvdb`, `imdb=tt<n>`, or `plex=<hash>` (the Plex GUID without `plex://movie/`) |
| `plezy://live?channel=<channel>` | Tunes a Live TV channel by key, number, or call sign. Optional `server=<server>` and `start=beginning\|live` |

For a show, `mode=next` (the default) plays the next episode to watch, and `mode=shuffle` plays the show shuffled. The menu of any movie, show, or episode has **Show link**, and each profile's menu in **Switch Profile** has **Show profile link**. Both show the link as text and a QR code.

```sh
# Android / Android TV, over adb (Home Assistant: remote.turn_on with activity: plezy://...)
adb shell am start -a android.intent.action.VIEW -d "plezy://play?type=show\&tvdb=81189\&profile=Kids"
# macOS
open "plezy://play?type=movie&tmdb=603"
```

On iOS, use the Open URLs action in Shortcuts.

## Building from Source

### Prerequisites
- Flutter SDK 3.47.0
- A Plex account, or a Jellyfin or Emby server with user credentials

### Setup

```bash
git clone https://github.com/snapetech-org/PlezyNG.git
cd Pleazyng
flutter pub get
scripts/codegen.sh
flutter run
```

<details>
<summary>Code generation</summary>

After modifying model classes or other generated sources:

```bash
scripts/codegen.sh
```

After modifying translations:

```bash
dart run slang
```

</details>

<details>
<summary>Packaging a Flatpak bundle</summary>

Packages an **already fully resolved Linux release bundle** — pinned libmpv and bundled libraries included, not a Flathub source-build manifest. Run it on Linux, on the same architecture as the bundle, after following the bundle preparation steps in [the Linux release workflow](.github/workflows/build.yml): `flutter build linux` alone does not produce all the required bundled libraries.

Install the packaging tools (Debian/Ubuntu shown) plus the native-architecture SDK and runtime:

```bash
sudo apt-get update
sudo apt-get install -y flatpak flatpak-builder imagemagick
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user flathub org.freedesktop.Platform//25.08 org.freedesktop.Sdk//25.08

BUNDLE_DIR=build/linux/x64/release/bundle
python3 linux/packaging/build-flatpak.py --bundle "$BUNDLE_DIR" --arch x64 --output "$PWD"
```

That writes `plezy-linux-x64.flatpak`, installable with the Flatpak commands above; on arm64, use the prepared arm64 bundle directory and `--arch arm64`. Package from the checkout matching the bundle, since the version comes from `pubspec.yaml`.

Cross-architecture packaging needs native Flatpak tools, a registered binfmt interpreter, and the target SDK/runtime installed with `flatpak install --user --arch=x86_64` (or `aarch64`) — never run Flatpak's namespace tools under emulation. Pass `--arch x64` or `--arch arm64` to the checker and the matching Flatpak architecture to `flatpak run --arch=...`.

Check the installed package against the runtime (not just the SDK), then launch it on a Wayland desktop and exercise streaming, audio, downloads/offline playback, and file chooser portals:

```bash
python3 linux/packaging/check-flatpak.py
```

The check fails on a non-executable entry point or an unresolved bundled ELF dependency. A container without a GPU can use `flatpak run --env=GALLIUM_DRIVER=softpipe org.snapetech.plezyng` for software-rendered verification; this is not a hardware-decoding or HDR test.

</details>

<details>
<summary>Local checks</summary>

```bash
scripts/ci_checks.sh
```

To install the same pre-commit checks locally:

```bash
scripts/setup_hooks.sh
```

End-to-end tests (Android emulator plus a Dockerized Jellyfin fixture):

```bash
python3 scripts/maestro/run_maestro.py basic
```

</details>

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development workflow, formatting, tests, and translation guidelines.

## License

Plezy is licensed under [GPL-3.0](LICENSE).

## Acknowledgments

- Built with [Flutter](https://flutter.dev)
- Supports [Plex Media Server](https://www.plex.tv), [Jellyfin](https://jellyfin.org), and [Emby](https://emby.media)
- Playback powered by [mpv](https://mpv.io) via our [mpv-build](https://github.com/edde746/mpv-build) pipeline (started as a fork of [MPVKit](https://github.com/mpvkit/MPVKit); on Android through its mpv-android library, whose Kotlin/JNI glue descends from [libmpv-android](https://github.com/jarnedemeulemeester/libmpv-android)), Android [ExoPlayer](https://developer.android.com/media/media3/exoplayer), and [libass-android](https://github.com/peerless2012/libass-android)
