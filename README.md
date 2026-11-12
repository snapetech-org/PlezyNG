<a href="https://pleazyng.app/">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/branding/pleazyng-artwork-dark.webp">
    <img src="assets/branding/pleazyng-artwork-light.webp" alt="Pleazyng — coral folded-ribbon identity" width="840">
  </picture>
</a>

<p>
  <a href="https://pleazyng.app/"><strong>plezyng.app</strong></a> · <a href="https://pleazyng.app/features.html">Feature comparison</a>
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
use automatic DV/FEL routing by default under **Settings → Playback**, with an
explicit Off override, compatibility fallback and optional diagnostic logging.
Implemented paths ship in normal compatible builds; a separate app build is not
required.

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
| Downloads | Converted download quality; per-rule quality; auto-download Continue Watching items and remove them when they leave the shelf ([#1145](https://github.com/edde746/plezy/issues/1145), [#1413](https://github.com/edde746/plezy/issues/1413), [#1847](https://github.com/edde746/plezy/pull/1847), [#1978](https://github.com/edde746/plezy/issues/1978), [#2181](https://github.com/edde746/plezy/issues/2181), [#2206](https://github.com/edde746/plezy/issues/2206)) | Code is implemented for Plex, Jellyfin, and Emby; validation against real servers remains pending. Jellyfin and Emby use progressive transcodes that restart after an interrupted transfer. |
| Downloads | Local Plex connections ([#1447](https://github.com/edde746/plezy/issues/1447)/[#2248](https://github.com/edde746/plezy/pull/2248)); download size and storage usage ([#2376](https://github.com/edde746/plezy/pull/2376)); manual sync and random episode selection ([#1197](https://github.com/edde746/plezy/pull/1197), [#1199](https://github.com/edde746/plezy/pull/1199)) | Implemented in Pleazyng |
| Downloads | Playlist downloads and watched-item cleanup ([#1721](https://github.com/edde746/plezy/issues/1721), [#2600](https://github.com/edde746/plezy/issues/2600), [#1413](https://github.com/edde746/plezy/issues/1413), [#2181](https://github.com/edde746/plezy/issues/2181)); orphan cleanup | Playlist downloads and watched-item cleanup are implemented. The Downloads screen can review and remove orphaned tagged files in the default app-managed folders; custom/SAF roots, legacy files, shared artwork, and iOS Documents are left untouched. |
| Profiles and privacy | PIN-gate download deletion, settings, and Explore; hide Explore per profile ([#1924](https://github.com/edde746/plezy/issues/1924), [#2514](https://github.com/edde746/plezy/issues/2514)) | Local profile PIN gates Settings, download deletion, and entry to Explore; Explore can also be hidden per profile. Plex Home PINs remain server-owned. |
| Audio and subtitles | Remember choices per show; choose tracks before playback; always-on subtitles and preferred-language fetching; per-item sync offsets ([#84](https://github.com/edde746/plezy/issues/84), [#1758](https://github.com/edde746/plezy/issues/1758), [#1956](https://github.com/edde746/plezy/pull/1956), [#2116](https://github.com/edde746/plezy/issues/2116), [#2182](https://github.com/edde746/plezy/issues/2182), [#2346](https://github.com/edde746/plezy/pull/2346), [#2382](https://github.com/edde746/plezy/issues/2382), [#2792](https://github.com/edde746/plezy/issues/2792)) | Code implements per-show memory, optional pre-play selection, device-local preferred-language selection and opt-in provider downloads, and scoped sync offsets across Plex, Jellyfin, and Emby. Per-show choices are app-profile local; real-server validation remains pending. Explicit server-selected tracks, account Off, and local picks remain authoritative. |
| Files and books | Standalone file sources, metadata, subtitles, ebooks and audiobooks | SMB2/3, optional encrypted NFSv3 RPC-with-TLS, FTP-family, SFTP, DLNA, Komga, WebDAV, S3, OPDS, cloud drives and Audiobookshelf; local Kodi/Jellyfin NFO/posters, confidence-gated Trakt metadata/cast/artwork/trailers, and OpenSubtitles search (including SMB; file-hash matching when an exact local or cached copy is available); EPUB/PDF/CBZ, multipart audiobook playback and progress sync through app-owned state files. Cloud sync never uploads or edits playback media. Availability varies by platform; see the [setup guide](docs/FILES_AND_BOOKS.md) for limits and security. |
| Universal media tools | Direct media URLs, radio playlists, local files, capture, sharing, extensions, Wi-Fi transfer, conversion, recording and picture controls | **Open media** handles session-only HTTP(S)/MPV streams, M3U/PLS/HLS playlists, temporary file and desktop folder queues, and supported ISO/disc inputs; the active source player offers queue browsing, upcoming-file shuffle, repeat, and item selection in one adaptive sheet. Eligible desktop queues can be saved as sibling-relative M3U files in current playback order. MPV exposes direct-input File Info and edition/disc-title choices when available. Safe stream favorites are profile-local. Desktop tools add screen/camera recording and live preview, temporary private-LAN HLS sharing, declarative HTTPS search extensions, `plezyctl` (Python 3.10+), FFmpeg conversion and MPV live-stream recording. See the [Open media guide](docs/UNIVERSAL_MEDIA.md) and [VLC feature comparison](docs/VLC_FEATURE_PARITY.md) for privacy and platform limits. |
| Cloud and add-on streaming | — | Real-Debrid/AllDebrid QR or PIN connection, Premiumize/TorBox API-key validation, on-demand cloud-file browsing through Files and books, cached cloud-video Search and Home posters, Stremio QR account linking with a selectable add-on import preview, and manual HTTPS add-on setup. Supported add-on catalogs appear in Explore; stream options open from existing title details. Matched server items use the shared video player and queue, with resume updates reconciled through the local watch queue. Credentials are encrypted and profile-scoped. Native peer-to-peer playback and canonical cloud/server library-card merging are implemented; live provider and packaged-device qualification remain open. Matched external playback reports active sessions through its owning server; live server acceptance remains pending. See the [connected streaming guide](docs/plezyng/remote-streams/README.md). |
| Subtitle controls | Live styling preview ([#2347](https://github.com/edde746/plezy/pull/2347)); in-player size and position controls ([#95](https://github.com/edde746/plezy/issues/95), [#689](https://github.com/edde746/plezy/issues/689), [#2174](https://github.com/edde746/plezy/issues/2174)); load a local subtitle file ([#1431](https://github.com/edde746/plezy/issues/1431)) | Local/archive import, dual-track controls, exact and cue-based sync, drift preview/undo, cue navigation/replay, and corrected export are implemented. Local AI workflows add WAV-based speech recognition, translation, automatic timing/cut repair, bilingual review, revision history and server attachment. Live capture, model availability and acceleration depend on the player and packaged runtime; device qualification remains open. See [Subtitles and local AI](#subtitles-and-local-ai). |
| Playback | Swipe-to-seek ([#2601](https://github.com/edde746/plezy/pull/2601)), frame stepping ([#1584](https://github.com/edde746/plezy/pull/1584)), subtitle-delay hotkeys ([#2824](https://github.com/edde746/plezy/pull/2824)), remembered version across episodes ([#2563](https://github.com/edde746/plezy/pull/2563)), video playlist repeat ([#1757](https://github.com/edde746/plezy/pull/1757)/[#1985](https://github.com/edde746/plezy/issues/1985)) | Implemented in Pleazyng |
| Playback | Plex cinema pre-rolls ([#970](https://github.com/edde746/plezy/issues/970)/[#2483](https://github.com/edde746/plezy/pull/2483)); random local pre-rolls ([#2271](https://github.com/edde746/plezy/pull/2271)); theme music ([#791](https://github.com/edde746/plezy/issues/791)/[#2170](https://github.com/edde746/plezy/pull/2170)/[#2596](https://github.com/edde746/plezy/pull/2596)) | Server-configured cinema intro code is present for Plex, Jellyfin, and Emby; real-server validation remains pending. Local pre-rolls, detail-page theme songs, and home spotlight music are implemented in the app. |
| Playback | Background video/audio-only mode ([#367](https://github.com/edde746/plezy/issues/367)), mpv equalizer ([#2292](https://github.com/edde746/plezy/pull/2292)), local/remote quality presets ([#2064](https://github.com/edde746/plezy/issues/2064)), opt-in TheIntroDB fallback ([#389](https://github.com/edde746/plezy/issues/389), [#1110](https://github.com/edde746/plezy/issues/1110), [#1886](https://github.com/edde746/plezy/pull/1886)) | Optional audio-only background playback is implemented on handheld Android and iOS; Android uses the OS media playback service. A ten-band device-local equalizer plus MPV stereo widening, room ambience, and pitch shift are available where the build and track support them; opt-in intro fallback is implemented. |
| Browsing | Director links ([#2762](https://github.com/edde746/plezy/pull/2762)), library item counts ([#1516](https://github.com/edde746/plezy/pull/1516)), Watchlist filters ([#2725](https://github.com/edde746/plezy/pull/2725)), MDBList Explore lists ([#2740](https://github.com/edde746/plezy/pull/2740)), Seerr search results ([#2811](https://github.com/edde746/plezy/pull/2811)) | Implemented in Pleazyng |
| Browsing | Search by actor or director ([#1517](https://github.com/edde746/plezy/issues/1517), [#2368](https://github.com/edde746/plezy/issues/2368)); random movie or library shuffle ([#1561](https://github.com/edde746/plezy/issues/1561), [#2741](https://github.com/edde746/plezy/issues/2741), [#2757](https://github.com/edde746/plezy/issues/2757)); show end time on detail pages ([#2671](https://github.com/edde746/plezy/issues/2671)) | People search, random movie selection, and shuffled playback of movie and TV libraries are implemented across connected servers; detail-page finish time is shown on media details |
| Home screen | Configurable rows, merged library and collection rows, organizer controls, and Plex account layout sync ([#1652](https://github.com/edde746/plezy/issues/1652)/[#2203](https://github.com/edde746/plezy/pull/2203)) | Implemented; Plex account sync applies to Plex profiles. Custom rows can combine selected libraries across connected servers |
| Home screen | Separate Next Up; hide empty libraries or backdrop art; Continue Watching row sizing ([#2498](https://github.com/edde746/plezy/pull/2498), [#2690](https://github.com/edde746/plezy/issues/2690), [#2701](https://github.com/edde746/plezy/issues/2701), [#2723](https://github.com/edde746/plezy/pull/2723), [#2784](https://github.com/edde746/plezy/issues/2784)) | Continue Watching and Next Up have separate Home rows and independent visibility/order. Empty-library filtering hides a library only when its server reports an explicit count of zero; unknown counts remain visible. Backdrop visibility and row sizing are implemented. The legacy hero banner visibility setting and TV clock already exist. |
| Servers and links | Preferred server ([#591](https://github.com/edde746/plezy/issues/591), [#1529](https://github.com/edde746/plezy/pull/1529), [#2720](https://github.com/edde746/plezy/issues/2720)); media watch links ([#2681](https://github.com/edde746/plezy/pull/2681)); return from external players with synced progress ([#2738](https://github.com/edde746/plezy/pull/2738)) | Preferred server is stored per profile and moves first in aggregate queries across Plex, Jellyfin, and Emby; watch links and external-player return sync are implemented |
| Live TV | Timeshift timeline ([#2300](https://github.com/edde746/plezy/pull/2300)) | Plex implementation is in the fork; Jellyfin/Emby DVR-window support remains under investigation because their public playback APIs do not expose the tuner's seekable capture window |
| Integrations | Google Cast ([#126](https://github.com/edde746/plezy/issues/126)); new-episode notifications ([#1146](https://github.com/edde746/plezy/issues/1146)); content screensaver ([#401](https://github.com/edde746/plezy/issues/401)) | Google Cast handoff code is implemented on Android and iOS through the default media receiver; receiver codec/container support and server reachability are required, and physical-receiver validation remains pending. Profile-scoped episode alerts poll connected Plex, Jellyfin, and Emby libraries while the app is foregrounded; Android/iOS device validation remains pending, and alerts do not have a background push source. The screensaver rotates artwork from selected connected libraries after an idle timeout. |
| Automation | Home Assistant control and Android automation intents ([#823](https://github.com/edde746/plezy/issues/823), [#1996](https://github.com/edde746/plezy/issues/1996)) | Android `ACTION_VIEW` links can open cross-server `pleazyng://watch` media, select an existing profile with `pleazyng://profile?id=…`, and control the active video session with `pleazyng://control` commands `play`, `pause`, `toggle`, or `stop`. Home Assistant can invoke these through an Android intent bridge; this does not expose Pleazyng as a native Plex Companion player in Home Assistant. See the [Android automation guide](docs/plezyng/android-automation.md). |
| Settings and diagnostics | Save logs to a file ([#2496](https://github.com/edde746/plezy/pull/2496)); cloud settings backup ([#1795](https://github.com/edde746/plezy/issues/1795)) | Log export is implemented; cloud settings backup uploads and restores only the portable settings JSON through an HTTPS WebDAV file endpoint. Server credentials, playback history and media files stay on their existing paths. |
| Cross-media discovery | — | Find your next combines media from configured sources with Saved picks, history/undo, comparison, local taste controls and co-present shortlist voting. Optional AI reranking and encrypted Saved-pick sync are opt-in; see the [delivery record](docs/plezyng/swipe/DELIVERY.md). |
| Listening and reading | — | Dedicated podcast discovery/subscriptions, OpenSubsonic music, EPUB/PDF/CBZ readers, Komga comics, Audiobookshelf and Hardcover shelf/progress integration extend the server libraries. See [Files, books and listening](docs/FILES_AND_BOOKS.md). |
| Games and media workspace | — | Experimental embedded GameStream/Steam receivers and an app-owned Multiview workspace are present in source. Native composition, simultaneous decoding, host sessions and device qualification remain platform-specific gates; see [Games](docs/games/ARCHITECTURE.md) and [Multiview](docs/plezyng/multiview/DELIVERY.md). |
| Playback experiments | — | Opt-in Neural motion processing, native projectM/MilkRust preset visualizers and Dolby Vision FEL work have separate runtime and qualification requirements. See [Experimental playback and workspace](#experimental-playback-and-workspace). |

This table is a snapshot of downstream work and its current limits. The linked upstream requests provide context for the gap Pleazyng addresses; equivalent upstream implementations can replace the corresponding downstream code when their behavior and server coverage match.

<p>
  <a href="https://pleazyng.app/">Website</a> ·
  <a href="https://github.com/edde746/plezy">Upstream Plezy</a> ·
  <a href="https://github.com/snapetech-org/pleazyng/issues">Pleazyng issues</a> ·
  <a href="#download">Download</a> ·
  <a href="CONTRIBUTING.md">Contributing</a> ·
  <a href="LICENSE">License</a>
</p>

<p align="center">
  <img src="assets/branding/pleazyng-artwork-dark.webp" alt="Pleazyng by SnapeTech — brand illustration" width="900" />
</p>

## Download

[Pleazyng 3.0.33 is published](https://github.com/snapetech-org/pleazyng/releases/tag/v3.0.33) with Android, Fire TV, Linux x64/ARM64, Windows x64/ARM64, universal macOS, iOS, tvOS, Tizen and webOS packages. See the [recorded GitHub publication evidence](docs/maintainers/releases/v3.0.33.json) and [all releases](https://github.com/snapetech-org/pleazyng/releases).

| Platform | Download |
| --- | --- |
| Desktop and mobile | [Release files for Android, Fire TV, Linux, Windows, macOS, iOS and tvOS](https://github.com/snapetech-org/pleazyng/releases/tag/v3.0.33) |
| webOS TV | [Experimental ARMv7 IPK](https://github.com/snapetech-org/pleazyng/releases/tag/v3.0.33); model/firmware and media playback qualification remain separate from publication. See the [compatibility matrix and port status](docs/maintainers/webos-tv.md). |
| Samsung Tizen TV | [Experimental ARM tester handoff](https://github.com/snapetech-org/pleazyng/releases/tag/v3.0.33); TV qualification and Tizen 10 remain pending. See the [build guide and rollout plan](docs/maintainers/tizen-tv.md). |

<details>
<summary>Install with a package manager</summary>

### macOS — Homebrew

Install the signed and notarized macOS release from the [Pleazyng Homebrew tap](https://github.com/snapetech-org/homebrew-pleazyng):

```bash
brew tap snapetech-org/pleazyng https://github.com/snapetech-org/homebrew-pleazyng
brew install --cask snapetech-org/pleazyng/snapetech-pleazyng
```

### Linux — Flatpak

Install Flatpak with your distribution's package manager, download the bundle for your architecture above, then run:

```bash
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user flathub org.freedesktop.Platform//25.08
flatpak install --user ./pleazyng-linux-x64.flatpak
flatpak run org.snapetech.pleazyng
```

On arm64, install `pleazyng-linux-arm64.flatpak`.

<details>
<summary>Sandbox, playback, and folder access</summary>

- Not on Flathub — the remote supplies the Freedesktop runtime only.
- Video playback needs a Wayland session; a pure X11 session shows the interface but cannot create the video plane.
- No broad access to your home or host filesystem by default; app data lives in `~/.var/app/org.snapetech.pleazyng/`. Specific runtime paths are available for media artwork and Discord integration. Grant access to additional folders through the desktop file chooser portal, and choose a writable download folder. User overrides can grant additional access.
- Network, display, audio, and device access are enabled. `--device=all` (Flatpak 1.14 compatibility) exposes more than GPUs and controllers; session-bus access stays filtered.

</details>

### Arch Linux — Pacman / AUR

Install [Pleazyng from the AUR](https://aur.archlinux.org/packages/pleazyng-bin) on x86_64 or ARM64:

```bash
git clone https://aur.archlinux.org/pleazyng-bin.git
cd pleazyng-bin
makepkg -si
```

The recipe downloads Pleazyng's own release bundles and verifies their checksums. It is separate from upstream Plezy's Arch package.

### Fedora — DNF / COPR

Install Pleazyng on supported Fedora releases, on x86_64 or ARM64, from the [Pleazyng COPR repository](https://copr.fedorainfracloud.org/coprs/slskdn/pleazyng/):

```bash
sudo dnf copr enable slskdn/pleazyng
sudo dnf install pleazyng
```

RHEL-compatible distributions need separate dependency qualification. The Flatpak bundle above is an alternative where Flatpak is supported.

### Nix

Run Pleazyng using its maintained flake on x86_64 Linux or ARM64 Linux:

```bash
nix run 'github:snapetech-org/pleazyng?dir=linux/packaging#pleazyng'
```

The flake pins nixpkgs and the published Pleazyng release. Native builds pass on both architectures; hardware playback qualification remains separate. The [nixpkgs contribution](https://github.com/NixOS/nixpkgs/pull/585758) is awaiting upstream review.

### aerynOS — Moss

An x86_64 recipe for packaging Pleazyng's Linux release bundle is available through the [Linux channel guide](docs/maintainers/linux-distribution-channels.md#aerynos). Native build and installation pass, but video playback in the v3.0.7 bundle fails [aerynOS qualification](docs/maintainers/aerynos-qualification.md). There is no official aerynOS repository entry for Pleazyng.

Package publication and store acceptance are separate from the complete GitHub release. See the [channel readiness and qualification steps](docs/maintainers/linux-distribution-channels.md).

</details>

## Android closed beta

Pleazyng's Google Play closed test is being prepared for `org.snapetech.pleazyng`. Once the test release is activated, invited testers can opt in at [the Pleazyng Google Play test page](https://play.google.com/apps/testing/org.snapetech.pleazyng). The link is inactive until then, and only accounts added to the test can join. For personal developer accounts subject to Google's [production-access testing requirements](https://support.google.com/googleplay/android-developer/answer/14151465), at least 12 testers must stay opted in continuously for 14 days before applying for production access. See the [publishing readiness checklist](docs/maintainers/publishing-readiness.md) for signing, billing, review and activation gates.

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
- [Minimal Requests](docs/SEERRNG_REQUESTS.md) — a native user-only Requests destination for movies, TV seasons, ebooks and audiobooks; SeerrNG provides book discovery/request APIs, with administration kept in its web interface
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
- [Play on another Pleazyng device](docs/plezyng/music/PLAY_ON.md) — paired handoff, live queue controls, return-to-device and optional encrypted cross-network relay
- Album and artist screens with play, shuffle, and Instant Mix
- Gapless playback with a full play queue — reorder, remove, play next, add to queue
- Now Playing with synced lyrics[^lyrics], persistent mini-player, and sleep timer
- Accessible visualizer that follows Plex analysis or optional live audio stats on compatible MPV builds
- Background playback with lock-screen, media-key, and notification controls[^bgaudio]
- Paired music transfer to compatible Pleazyng sessions, with a [managed Linux ARM64 / Raspberry Pi endpoint](scripts/music_endpoint/README.md)
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
- See the [Games architecture](docs/games/ARCHITECTURE.md) and [validation record](docs/games/VALIDATION.md). HDR presentation and paired internet traversal are implemented in source; native build coverage and real host/controller/device/network qualification vary by platform.

### Experimental playback and workspace

- **Neural motion processing:** opt-in desktop PME, Android LiteRT/QNN and Apple paths, on-demand verified model packs with progress, live Performance/Balanced/Quality switching where supported, capability diagnostics and smoothing/normal-playback fallbacks. Real-time device and presentation qualification remains separate; see [motion processing](docs/plezyng/motion-processing.md).
- **Dolby Vision FEL:** Linux reconstruction engine, Android synthetic experiment, Apple dual-layer host and offline FEL-to-HDR/SDR pipeline. Implemented paths are included in normal compatible builds and requested automatically by default, with compatibility fallback and a persisted Off override. Platform/display qualification remains separate; see [Dolby Vision experiments](#dolby-vision-experiments).
- **Multiview:** app-owned floating/side-by-side media workspace with session tray, move/resize/return controls, separate audio/input ownership and capability-gated video, reading, music and Steam surfaces. The workspace reserves two native video slots and implements detached desktop video windows; concurrent decoding, native composition and platform/device acceptance remain unverified. See the [workspace delivery record](docs/plezyng/multiview/DELIVERY.md).
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
- [`pleazyng://` links](#pleazyng-links) to open a profile, play a title, or tune a channel from Home Assistant, launchers, or an NFC tag; any movie, show, or episode menu shows its link[^links]

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
[^mpv]: Requires MPV; Android defaults to ExoPlayer. Apple GLSL presets and ambient lighting use the AVFoundation shader stage, which skips Dolby Vision and composited picture-in-picture frames. See [playback compositor behavior](docs/plezyng/playback-compositor.md).
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

## Feature comparison

[Read the full-width feature comparison on the website](https://pleazyng.app/features.html).

Pleazyng inherits Plezy's feature baseline. The tables focus on what differs:
what the official Plex ecosystem offers that these clients do not replace,
what both forks offer beyond Plex, and what Pleazyng adds to Plezy.

**Reviewed 2026-11-09.** **Yes** means a documented built-in capability, subject
to the noted platform/server requirements. **—** means no equivalent was found
in the audited feature inventory; third-party plugins and external workarounds
are not counted. **Experimental** and **Partial** describe implemented paths
with remaining qualification or functionality limits. Plex includes its
official apps, Plex Media Server, Plexamp and Plex Photos where named.
Each cell puts its status first, with scope notes in italic parentheses below it.
See the [comparison notes, sources and remaining gaps](docs/FEATURE_COMPARISON.md).

### Capabilities outside these clients

| Feature | Plex | Plezy | Pleazyng |
| --- | --- | --- | --- |
| [Full browser player and server-management UI](docs/FEATURE_COMPARISON.md#browser-client) | **Yes** | **—** | **—**<br>*(browser-based book reading is a separate feature)* |
| [Roku, PlayStation and Xbox apps](docs/FEATURE_COMPARISON.md#device-coverage) | **Yes** | **—** | **—** |
| [Free movies/shows and FAST channels](docs/FEATURE_COMPARISON.md#plex-hosted-content) | **Yes** | **—** | **—**<br>*(personal-server TV and independent IPTV are different sources)* |
| [Movie rentals and purchases](docs/FEATURE_COMPARISON.md#rentals-and-purchases) | **Yes** | **—** | **Storefront links only**<br>*(no rental-library playback)* |
| [Photo libraries, albums and slideshows](docs/FEATURE_COMPARISON.md#photo-libraries) | **Yes** | **—** | **—**<br>*(artwork screensavers and comic images are not photo-library support)* |
| [Social profiles and shareable lists](docs/FEATURE_COMPARISON.md#social-and-lists) | **Yes** | **Watchlist/catalog integration only** | **Watchlist/catalog integration and local shortlists**<br>*(no equivalent social network)* |
| [Interactive music journeys and AI DJ controls](docs/FEATURE_COMPARISON.md#plexamp-specialized-features) | **Yes** | **—**<br>*(ordinary Instant Mix is available)* | **—**<br>*(ordinary Instant Mix is available)* |
| [CarPlay / Android Auto projection, Siri music integration](docs/FEATURE_COMPARISON.md#car-and-voice-integrations) | **Yes** | **—** | **—**<br>*(Android Automotive layout detection is not a projection integration)* |
| [Headless Raspberry Pi music endpoint](docs/FEATURE_COMPARISON.md#headless-music) | **Yes** | **—** | **—** |
| [Companion remote protocol / Alexa / Sonos integrations](docs/FEATURE_COMPARISON.md#companion-protocol) | **Limited**<br>*(platform restrictions apply)* | **Own Plezy Remote protocol** | **Own remote and automation links**<br>*(different protocol)* |
| [Server-assisted external-SRT Auto-Sync](docs/FEATURE_COMPARISON.md#server-subtitle-auto-sync) | **Yes** | **—** | **Local subtitle tools**<br>*(no equivalent server auto-sync request workflow)* |
| [Server hosting, analysis and sharing administration](docs/FEATURE_COMPARISON.md#server-owned-capabilities) | **Yes** | **Uses an existing server** | **Uses an existing server**<br>*(does not replace its administration or analysis)* |

### Plezy features inherited by Pleazyng that differ from Plex

These are shared fork features, not Pleazyng-only additions. Their
[in-repo baseline notes](docs/FEATURE_COMPARISON.md#inherited-plezy-baseline)
link the audited upstream inventory.

| Feature | Plex | Plezy | Pleazyng |
| --- | --- | --- | --- |
| [Plex, Jellyfin and Emby together in one client](docs/FEATURE_COMPARISON.md#inherited-plezy-baseline) | **Plex servers only** | **Yes** | **Yes**<br>*(inherited)* |
| [Combined cross-backend search and duplicate-copy selection](docs/FEATURE_COMPARISON.md#inherited-plezy-baseline) | **Plex ecosystem** | **Yes** | **Yes**<br>*(inherited, extended with Files/books/catalogs)* |
| [Trakt, MyAnimeList, AniList and Simkl catalogs, watchlists and scrobbling](docs/FEATURE_COMPARISON.md#inherited-plezy-baseline) | **No equivalent built-in multi-tracker workflow** | **Yes** | **Yes**<br>*(inherited)* |
| [Seerr requests with season, 4K and destination choices](docs/FEATURE_COMPARISON.md#inherited-plezy-baseline) | **External tools needed** | **Yes** | **Yes**<br>*(inherited)* |
| [Open Watch Party across users' own Plex/Jellyfin/Emby copies](docs/FEATURE_COMPARISON.md#inherited-plezy-baseline) | **Plex Watch Together remains in Web**<br>*(being retired from new native apps)* | **Yes** | **Yes**<br>*(inherited; additional recovery/room controls)* |
| [MPV shader controls and configurable ASS/SSA rendering](docs/FEATURE_COMPARISON.md#inherited-plezy-baseline) | **Client-dependent subtitle/rendering controls** | **Yes**<br>*(supported player paths)* | **Yes**<br>*(inherited, with additional tools below)* |
| [External Android player handoff with progress returned to the app](docs/FEATURE_COMPARISON.md#inherited-plezy-baseline) | **No equivalent documented workflow** | **Yes** | **Yes**<br>*(inherited)* |
| [Open-source application that can be built and modified](docs/FEATURE_COMPARISON.md#inherited-plezy-baseline) | **Official apps/server are proprietary** | **Yes**<br>*(GPL-3.0)* | **Yes**<br>*(GPL-3.0; dependencies retain their own licenses)* |

### Pleazyng additions without an equivalent in either inventory

Each feature name links to its in-repo operating guide or implementation record.
These rows describe the specific workflow named, rather than claiming that Plex
lacks music, subtitles, recommendations or file playback in general.

| Feature | Plex | Plezy | Pleazyng |
| --- | --- | --- | --- |
| [Serverless Files and books profiles](docs/FILES_AND_BOOKS.md) | **—** | **—** | **Yes**<br>*(no media-server account needed)* |
| [Direct SMB, NFS, FTP/FTPS, SFTP, DLNA, WebDAV and S3 source browsing](docs/FILES_AND_BOOKS.md) | **Server can mount storage**<br>*(not this direct-client workflow)* | **—** | **Yes**<br>*(provider/platform limits apply)* |
| [Google Drive, OneDrive and Dropbox source libraries](docs/FILES_AND_BOOKS.md) | **—** | **—** | **Yes**<br>*(configured account/provider required)* |
| [Local/NAS video libraries with NFO/poster sidecars and metadata matching](docs/FILES_AND_BOOKS.md) | **Server-managed libraries instead** | **—** | **Yes**<br>*(direct-source indexing, offline sidecars and confidence-gated lookups)* |
| [OPDS catalogs and EPUB/PDF reading with notes, highlights and read-along](docs/FILES_AND_BOOKS.md) | **—** | **—** | **Yes**<br>*(document reading is not available on TV; Linux uses a browser surface)* |
| [Komga / CBZ comic reading with spreads, RTL and page controls](docs/plezyng/comics/DELIVERY.md) | **—** | **—** | **Yes**<br>*(reader/platform qualification limits documented)* |
| [Audiobookshelf and dedicated multipart audiobook workflows](docs/FILES_AND_BOOKS.md) | **Music-library workarounds, not a dedicated book client** | **—** | **Yes**<br>*(ordering, chapters, bookmarks, speed and resume)* |
| [Hardcover shelves and edition-aware reading-progress updates](docs/plezyng/service-integrations/README.md) | **—** | **—** | **Yes**<br>*(preview/undo; exact edition matching)* |
| [Open Library / Google Books discovery and book/comic storefront handoffs](docs/plezyng/service-integrations/README.md) | **Video discovery, not these book workflows** | **—** | **Yes**<br>*(catalog/link access does not imply ownership or playback)* |
| [Encrypted reading/listening progress and annotation sync](docs/FILES_AND_BOOKS.md) | **—** | **—** | **Yes**<br>*(supported storage targets; explicit conflict resolution)* |
| [Find your next mixed-media discovery deck](docs/plezyng/swipe/README.md) | **Video discovery, not a mixed book/comic/audio/video deck** | **—** | **Yes**<br>*(source, genre, mood, familiarity and offline filters)* |
| [Saved picks, undo/history, pick comparison and co-present voting](docs/plezyng/swipe/DELIVERY.md) | **Watchlists/Lists, not this local decision workflow** | **—** | **Yes**<br>*(optional encrypted sync)* |
| [User-configured AI reranking of mixed-media picks](docs/plezyng/swipe/README.md) | **—** | **—** | **Opt-in**<br>*(ordinary ranking remains available)* |
| [Debrid cloud-file libraries and durable preparation jobs](docs/plezyng/remote-streams/README.md) | **—** | **—** | **Implemented**<br>*(Real-Debrid, AllDebrid, Premiumize and TorBox; live-provider qualification remains open)* |
| [Stremio add-on catalogs and stream selection](docs/plezyng/remote-streams/README.md) | **—** | **—** | **Implemented**<br>*(HTTPS add-ons, account import and source-local resume)* |
| [Native libtorrent source streaming](docs/plezyng/remote-streams/IMPLEMENTATION.md) | **—** | **—** | **Requires the compatible packaged runtime**<br>*(provider/device limits apply)* |
| [OpenSubsonic/Subsonic music-server browsing and playback](docs/FILES_AND_BOOKS.md) | **Plex music servers only** | **—** | **Yes**<br>*(configured server; local resume, no provider-side scrobbling)* |
| [RSS/Atom podcasts, directory discovery, OPML and podcast chapters](docs/plezyng/podcasts/IMPLEMENTATION.md) | **Native podcast service retired** | **—** | **Yes**<br>*(Apple Podcasts / optional Podcast Index / Audiobookshelf)* |
| [Podcast auto-download/retention and optional gpodder sync](docs/plezyng/podcasts/CLIENT_CONTRACT.md) | **—** | **—** | **Implemented**<br>*(protocol/device qualification limits apply)* |
| [Karaoke songbook, singer rotation and CD+G/timed-lyric workflows](docs/plezyng/karaoke/PLAN.md) | **—** | **—** | **Partial**<br>*(licensed catalogs and native microphone monitoring remain open)* |
| [Profile-owned M3U/XMLTV, Xtream, Tunerr, Dispatcharr and Stalker IPTV](docs/plezyng/iptv/PLAN.md) | **Tuner/DVR support is a different workflow** | **—** | **Partial**<br>*(source adapters exist; plan reconciliation, provider and device acceptance remain open)* |
| [Universal network inputs, radio playlists, ISO/disc inputs and source queues](docs/UNIVERSAL_MEDIA.md) | **Some apps open local video**<br>*(no equivalent universal input workflow)* | **—** | **Yes**<br>*(HTTP(S), HLS, RTSP/RTMP, UDP/RTP and supported file/disc paths)* |
| [Desktop folder queues and sibling-relative M3U export](docs/UNIVERSAL_MEDIA.md) | **—** | **—** | **Yes**<br>*(explicit local inputs and bounded scans)* |
| [Foreground Wi-Fi file transfer into profile-owned storage](docs/UNIVERSAL_MEDIA.md#transfer-files-over-wi-fi) | **—** | **—** | **Yes**<br>*(desktop/handheld Android; active session required)* |
| [Desktop screen/camera capture and live preview](docs/UNIVERSAL_MEDIA.md) | **—** | **—** | **Yes**<br>*(compatible devices/FFmpeg/MPV required)* |
| [Temporary private-LAN HLS sharing](docs/UNIVERSAL_MEDIA.md) | **Media Server sharing is a different service** | **—** | **Yes**<br>*(session-owned sharing from desktop)* |
| [Local conversion/remux and live-stream recording](docs/UNIVERSAL_MEDIA.md) | **Server optimization is a different workflow** | **—** | **Yes**<br>*(supported desktop tools/encoders required)* |
| [Data-only search extensions and bundled `plezyctl` media tools](docs/UNIVERSAL_MEDIA.md) | **Public API, not this bundled tool workflow** | **—** | **Yes**<br>*(HTTPS search providers and existing Open media UI)* |
| [Named local playback bookmarks and A/B segment looping](docs/VLC_FEATURE_PARITY.md) | **—** | **—** | **Yes**<br>*(supported seekable player paths)* |
| [Local speech-to-subtitle, translation and bilingual revision review](docs/plezyng/subtitles/PLAN.md) | **Subtitle search/auto-sync, not a local transcription/translation editor** | **—** | **Implemented**<br>*(local models/audio inputs and export/attachment limits apply)* |
| [Live caption/transcript capture and search](docs/plezyng/subtitles/LIVE_CAPTURE.md) | **—** | **—** | **Partial**<br>*(native capture/backend support required; webOS needs supplied audio)* |
| [Motion & clarity presets, blending and motion-compensated frame generation](docs/plezyng/motion-clarity/guide.md) | **—**<br>*(TV/driver processing is external)* | **—** | **Yes on compatible MPV paths**<br>*(platform limits apply)* |
| [Neural / NPU motion processing](docs/plezyng/motion-processing.md) | **—** | **—** | **Experimental**<br>*(included on compatible platforms; Settings opt-in, off by default)* |
| [Dolby Vision Profile 7 FEL reconstruction experiments](docs/maintainers/dv-platform-buildout.md) | **Native DV playback is not a general FEL reconstruction control** | **—** | **Experimental**<br>*(normal compatible builds; automatic by default with compatibility fallback)* |
| [Offline FEL-to-HDR/SDR processing tools](docs/maintainers/dv-platform-buildout.md) | **—** | **—** | **Experimental**<br>*(packaged compatible tools; output qualification remains separate)* |
| [Importable projectM/MilkRust visualizer preset packs](docs/plezyng/visualizations/USER_GUIDE.md) | **Built-in Plexamp visuals, not this preset-pack workflow** | **—** | **Experimental**<br>*(native engine/PCM/runtime requirements apply)* |
| [Embedded GameStream/Moonlight game receiver](docs/games/ARCHITECTURE.md) | **Plex Arcade retired**<br>*(not a GameStream client)* | **—** | **Experimental**<br>*(Android and compatible hosts)* |
| [Embedded Steam receivers and game-session controls](docs/games/ARCHITECTURE.md) | **—** | **—** | **Experimental**<br>*(host, SDK and network qualification varies)* |
| [RomM catalogs, play routes, offline games and save sync](docs/games/ROMM_INTEGRATION.md) | **—** | **—** | **Partial**<br>*(core/signing/device limits documented)* |
| [App-owned floating / side-by-side Multiview workspace](docs/plezyng/multiview/DELIVERY.md) | **—** | **—** | **Partial**<br>*(two video slots and detached desktop windows are implemented in source; concurrent decoding/composition remain unverified)* |
| [Local PIN gates for Settings, download deletion and Explore](docs/plezyng/HANDOFF.md#implemented-in-this-work-branch) | **Plex Home PIN is a different account control** | **—** | **Yes**<br>*(profile-local gates and Explore visibility)* |
| [Portable settings backup/restore through HTTPS WebDAV](docs/plezyng/HANDOFF.md#remaining-work-and-platform-limits) | **—** | **Local settings import/export only** | **Yes**<br>*(excludes credentials, media and history)* |

### Other Pleazyng extensions to existing features

Plex already offers versions of these capabilities. The difference is the
specific controls, backend coverage or platform route, not exclusive ownership
of the whole feature category.

| Feature | Plex | Plezy | Pleazyng |
| --- | --- | --- | --- |
| [Converted downloads, per-rule quality and Continue Watching cleanup](docs/plezyng/HANDOFF.md#implemented-in-this-work-branch) | **Downloads, quality and keep/unplayed rules**<br>*(Plex requirements apply)* | **Downloads and automatic sync rules** | **Adds per-rule quality, shelf-driven cleanup and cross-server conversion**<br>*(live-server limits documented)* |
| [Pre-play track selection, per-show memory and subtitle automation](docs/plezyng/HANDOFF.md#implemented-in-this-work-branch) | **Account/player track preferences and subtitle search** | **Per-title/server track choices** | **Adds per-show and pre-play workflows, preferred-language fetching and scoped offsets** |
| [Dual subtitles, cue alignment and drift/cut correction](docs/plezyng/subtitles/PLAN.md) | **Server-assisted external-SRT Auto-Sync with Plex Pass** | **Track, styling and timing controls** | **Adds local cue/two-anchor/review tools on compatible paths**<br>*(not identical to Plex Auto-Sync)* |
| [Ten-band EQ and video/audio effects](docs/VLC_FEATURE_PARITY.md) | **Plexamp music EQ** | **Passthrough/channel/loudness controls** | **Adds MPV EQ, stereo widening, ambience and pitch controls**<br>*(effects disable passthrough)* |
| [Loudness-aware Sweet Fades and recorded-commercial marker skipping](docs/FEATURE_COMPARISON.md#client-playback-extensions) | **Yes**<br>*(Plexamp / compatible Plex players)* | **Not listed in audited upstream features** | **Adds opt-in music fades and commercial-marker controls using server-provided data** |
| [Merged/custom Home rows and presentation controls](docs/plezyng/HANDOFF.md#implemented-in-this-work-branch) | **Customizable Plex sources/recommendations** | **TV layout and spotlight controls** | **Adds cross-server row composition, row sizing and separate Continue Watching / Next Up** |
| [Google Cast handoff](docs/plezyng/HANDOFF.md#implemented-in-this-work-branch) | **Yes**<br>*(supported controller apps)* | **Not listed in audited upstream features** | **Android/iOS handoff and progress reporting**<br>*(receiver/network limits apply)* |
| [LG webOS and Samsung Tizen packages](docs/FEATURE_COMPARISON.md#native-tv-ports) | **Official apps** | **Not in audited upstream targets** | **Published native packages**<br>*(model/firmware and device qualification remain limited)* |
| [Media/profile/control automation links](docs/plezyng/android-automation.md) | **Plex-specific integrations** | **Upstream app links and Plezy Remote** | **Canonical `pleazyng://` links, profile selection and active-video controls** |
| [LG native audio/subtitle paths and playback diagnostics](docs/maintainers/webos-tv.md) | **Device-dependent codecs/subtitle rendering** | **No upstream LG port** | **Native LG route**<br>*(SUP-sidecar overlay and source-aware diagnostics have documented limits)* |

<details>
<summary>Shared feature baseline — already present in Plezy and retained by Pleazyng</summary>

| Feature family | Plex | Plezy | Pleazyng |
| --- | --- | --- | --- |
| Movie/TV libraries, collections, playlists, search, filters and extras | **Yes** | **Yes** | **Yes**<br>*(inherited)* |
| Continue Watching, resume, queues, shuffle, autoplay, chapters and thumbnails | **Yes** | **Yes** | **Yes**<br>*(inherited)* |
| Direct play, server transcodes, track selection, HDR/DV and passthrough | **Client/server/device dependent** | **Yes**<br>*(compatible paths)* | **Yes**<br>*(inherited; platform limits apply)* |
| Subtitles, styling, online search, speed, zoom, PiP and refresh matching | **App/device dependent**<br>*(some Plex Pass features)* | **Yes**<br>*(compatible paths)* | **Yes**<br>*(inherited and extended)* |
| Music browsing, Instant Mix, gapless queues, lyrics and background controls | **Yes**<br>*(Plexamp / supported apps)* | **Yes** | **Yes**<br>*(inherited)* |
| Personal-server Live TV, EPG and DVR controls | **Yes**<br>*(tuner/server/Plex Pass requirements)* | **Yes**<br>*(backend dependent)* | **Yes**<br>*(inherited and extended)* |
| Offline downloads, queue management and automatic sync | **Plex Pass / supported clients** | **Yes**<br>*(no tvOS downloads)* | **Yes**<br>*(inherited and extended)* |
| Profiles, Plex Home PIN switching, watch-state sync and metadata/art editing | **Yes**<br>*(appropriate permissions)* | **Yes** | **Yes**<br>*(inherited)* |
| Remote-friendly navigation, desktop/mobile/TV layouts and platform integrations | **App dependent** | **Yes** | **Yes**<br>*(inherited)* |
| Windows, macOS, Linux, Android/Fire TV, iOS and tvOS clients | **Yes** | **Yes** | **Yes**<br>*(inherited)* |

</details>

Plex server/account entitlements still apply where Plex enforces them, including
remote streaming, Downloads, DVR and server analysis. Neither client grants
Plex Pass or replaces server hardware transcoding. Provider-gated
[OverDrive lending](docs/LENDING_SETUP.md), [Watchmode/MusicKit pilots](docs/plezyng/service-integrations/README.md)
and the [deferred full Discord client](docs/plezyng/discord/DELIVERY.md) are not
counted as generally available features. Dolby Vision/FEL routing is automatic by default with compatibility fallback; neural motion processing remains opt-in;
see the linked qualification records before assuming a particular device works.

## pleazyng:// links

Pleazyng generates canonical `pleazyng://` links. Use the hosts and parameters below to start Pleazyng from outside the app. Any link may add `profile=<profile>`: a profile id, a Plex Home user UUID, or a display name (ignoring case; it must match one profile). Pleazyng switches to that profile first, and a protected profile still asks for its PIN. A link replaces whatever is playing.

| Link | Does |
|---|---|
| `pleazyng://open` | Opens Pleazyng |
| `pleazyng://play?server=<server>&id=<item>` | Plays one item on one server, any backend |
| `pleazyng://play?type=movie\|show&tmdb=<n>` | Plays a title from whichever server has it. Use `tmdb`, `tvdb`, `imdb=tt<n>`, or `plex=<hash>` (the Plex GUID without `plex://movie/`) |
| `pleazyng://live?channel=<channel>` | Tunes a Live TV channel by key, number, or call sign. Optional `server=<server>` and `start=beginning\|live` |

For a show, `mode=next` (the default) plays the next episode to watch, and `mode=shuffle` plays the show shuffled. The menu of any movie, show, or episode has **Show link**, and each profile's menu in **Switch Profile** has **Show profile link**. Both show the link as text and a QR code.

```sh
# Android / Android TV, over adb (Home Assistant: remote.turn_on with activity: pleazyng://...)
adb shell am start -a android.intent.action.VIEW -d "pleazyng://play?type=show\&tvdb=81189\&profile=Kids"
# macOS
open "pleazyng://play?type=movie&tmdb=603"
```

On iOS, use the Open URLs action in Shortcuts.

## Building from Source

### Prerequisites
- Flutter SDK 3.47.8 (tvOS builds use the separately pinned custom 3.47.1 engine)
- A Plex account, or a Jellyfin or Emby server with user credentials

### Setup

```bash
git clone https://github.com/snapetech-org/pleazyng.git
cd pleazyng
flutter pub get
scripts/codegen.sh
flutter run
```

For a Windows source build, install the [qualified patched Flutter runtime components](https://github.com/snapetech-org/pleazyng/releases/tag/flutter-security-3.47.8) into the matching Flutter 3.47.8 SDK cache after precaching. The script downloads and checks the architecture-specific archive against its pinned SHA-256 digest:

```powershell
flutter precache --windows
.\windows\tool\install-patched-engine.ps1 -Architecture x64
# Use -Architecture arm64 on a native ARM64 build host.
```

These ZIP files are Flutter engine components for building Pleazyng, not Pleazyng installers. For app downloads, use the [Pleazyng release](https://github.com/snapetech-org/pleazyng/releases/tag/v3.0.7). Re-run the script after an SDK upgrade or forced precache.

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

That writes `pleazyng-linux-x64.flatpak`, installable with the Flatpak commands above; on arm64, use the prepared arm64 bundle directory and `--arch arm64`. Package from the checkout matching the bundle, since the version comes from `pubspec.yaml`.

Cross-architecture packaging needs native Flatpak tools, a registered binfmt interpreter, and the target SDK/runtime installed with `flatpak install --user --arch=x86_64` (or `aarch64`) — never run Flatpak's namespace tools under emulation. Pass `--arch x64` or `--arch arm64` to the checker and the matching Flatpak architecture to `flatpak run --arch=...`.

Check the installed package against the runtime (not just the SDK), then launch it on a Wayland desktop and exercise streaming, audio, downloads/offline playback, and file chooser portals:

```bash
python3 linux/packaging/check-flatpak.py
```

The check fails on a non-executable entry point or an unresolved bundled ELF dependency. A container without a GPU can use `flatpak run --env=GALLIUM_DRIVER=softpipe org.snapetech.pleazyng` for software-rendered verification; this is not a hardware-decoding or HDR test.

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

## Upstream sources

Feature history links in **What Pleazyng has built** lead to the original
Plezy PRs and issues. The [source ledger](UPSTREAM_ATTRIBUTION.md) credits
their upstream authors and separates adapted code, reports, proposals and
planned work. Pleazyng independently adapted or verified the relevant
behavior; those authors contributed to upstream Plezy. Relevant feature
guides include their own source footers.
