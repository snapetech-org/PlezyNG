# PlezyNG feature build-out handoff

Status: 2026-10-28. PlezyNG is a fork of `edde746/plezy` intended to carry requested features that upstream declined or has not shipped, while keeping parity across Plex, Jellyfin, and Emby where the APIs allow it. The fork should retire as the corresponding capabilities converge upstream.

## Current audit remediation status

The 26 October engineering audit is pinned to main commit `c781dd83d69025c8596ace69f40352d982dc4ba7`, not this work branch. Its F01–F16 findings have been rechecked against current source and are tracked in the [capability and qualification ledger](../maintainers/capability-manifest.json). That ledger separates code present from CI, provider, native-device and public-release evidence. This work slice has not run tests, analysis, native builds or GitHub Actions.

## Implemented in this work branch

- Converted video download quality for Plex, Jellyfin, and Emby. Plex uses its download queue; Jellyfin and Emby use progressive H.264/AAC transcodes and restart after interrupted transfers because those streams are not resumable.
- Per-sync-rule quality, per-download quality prompt, and automatic Continue Watching rules with cleanup when items leave the shelf.
- Server-configured Plex pre-rolls and Jellyfin/Emby cinema intros, with local random movie pre-rolls as the fallback.
- Per-show audio and subtitle memory stored locally by app profile, in addition to existing Plex/Jellyfin server memory.
- Optional pre-play audio and subtitle selection using the same source track metadata as the player, across Plex, Jellyfin, and Emby.
- Preferred-language subtitle selection is a device-local playback policy. Its opt-in setting selects an existing track or asks Plex, Jellyfin, or Emby to fetch one, then attaches the returned subtitle as a sidecar. Automatic selections are never written to the account; explicit server-selected tracks, account Off, and user Off choices take precedence.
- In-player subtitle size/position controls and loading a local subtitle file in mpv.
- Theme-song playback on the active TV home spotlight, using the existing cross-server theme-song controller.
- Resolve watch links for Jellyfin and Emby by IMDb/TMDB/TVDB ID, falling back to a server-specific link when metadata is incomplete.
- Configurable Home rows, merged library and collection rows, organizer controls, and Plex account layout sync from upstream #2203. Custom rows can include selected Plex, Jellyfin, and Emby libraries; native Plex Home rows and account sync remain Plex-specific.
- A local profile PIN can gate Settings, download deletion, and entry to Explore. Explore visibility is configurable per profile; the app does not replace Plex Home's server-owned PIN.
- Hide libraries only when a backend explicitly reports zero items, choose a random movie or shuffle a movie/TV library, estimate a detail page's finish time, and export diagnostic logs to a file.
- Hide Home hero/spotlight artwork or choose a compact, standard, or large Continue Watching row.
- Choose a preferred server per profile; it is queried first while all Plex, Jellyfin, and Emby servers remain available.
- Keep Continue Watching and Next Up in separate Home rows, each with its own visibility and organizer position.
- Five-band, device-local audio equalizer for mpv video playback; gains compose with loudness normalization and are stored in portable settings.
- Optional audio-only video continuation when a handheld Android or iOS app backgrounds; Android uses the existing OS media playback foreground service.
- Google Cast discovery, playback handoff, subtitle sidecars, remote pause/resume/stop controls, and server progress reporting on Android and iOS. Plex, Jellyfin, and Emby streams use their existing external-playback resolvers and the default Cast media receiver.
- Android automation links can launch cross-server watch links, select an existing profile, and control the active video session with play, pause, toggle, or stop. Profile detail screens can copy the selection link, and profile activation follows the regular PIN/Plex Home verification flow. See [Android automation links](android-automation.md).
- Profile-scoped new-episode notifications scan connected Plex, Jellyfin, and Emby libraries while the app is foregrounded on Android/iOS. Initial scans establish a baseline; alerts are limited to shows whose earlier episodes are watched.
- An idle content screensaver rotates artwork from selected libraries across connected servers, with configurable delay and dismiss controls.
- Optional TheIntroDB community intro timings are queried only when no server or chapter-derived intro exists. The setting is off by default and requires a catalog ID and internet access.
- People search and offline playlist downloads were already present in the merged code. Existing watched-download cleanup and per-item sync offsets were also present.
- The Downloads screen can review and remove orphaned tagged media, episode thumbnails, and numeric-ID subtitle sidecars from PlezyNG's default app-managed folders. The scan preserves database-owned or active-task files, custom/SAF roots, iOS Documents, legacy paths, shared artwork, unknown files, and symlinks.
- The earlier 23 upstream PR integrations remain on `main`, including local Plex connections, download storage reporting, deep links, external-player return sync, repeat playlists, swipe/frame controls, subtitle preview and delay hotkeys, bulk selection, prerolls, live-TV timeshift, theme songs, and download sync actions.

## Remaining work and platform limits

| Area | Remaining work |
| --- | --- |
| Downloads | Verify converted downloads against real Plex/Jellyfin/Emby servers; orphan cleanup is implemented for the default app-managed folders only |
| Profiles | Implementation is complete: the app-local PIN gates Settings, download deletion, and Explore; Explore visibility is per profile. Plex Home PINs remain server-owned. |
| Audio/subtitles | Validate per-show memory, pre-play selection, and automatic subtitle fetching against real Plex/Jellyfin/Emby servers |
| Browsing | Finish-time estimate is shown on media details; check platform layouts during release validation |
| Home | Backdrop-art visibility and Continue Watching row sizing are implemented. Empty-library filtering applies when the server reports an explicit zero. The legacy hero banner already has a visibility setting; the top-bar clock is available on TV. |
| Live TV | Jellyfin/Emby do not expose a seekable capture-window snapshot in their public playback responses, so the app cannot safely map their live buffer to the absolute-time timeline used by Plex |
| Integrations | Notifications are foreground-polled only; they pause when the OS suspends Plezy. There is no background push source. Google Cast uses the default Cast media receiver and needs validation with physical receivers; the receiver must support the stream format and reach the server. |
| Automation | Android intent links provide direct media launch, profile selection, and active-video controls. Plezy does not yet advertise itself as a native Plex Companion player to Home Assistant's Plex integration. |
| Settings | HTTPS WebDAV backup of the portable settings export is implemented. Configure a file URL ending in `.json`, optionally with WebDAV credentials; local server connections, tokens, download locations, and history are excluded. |
| webOS TV | An experimental ARM IPK was installed and launched on one LG C6; its app and native library hashes match the package. Plex login, artwork/cards, and playback were confirmed on an earlier build, and secure-store write/read/delete passed. The latest package's current UI frame, token persistence, Jellyfin/Emby, broader device coverage, and release packaging remain unverified; see [webOS port status](../maintainers/webos-tv.md). |

## Historical validation and cautions

The results below belong to an earlier feature checkout and do not qualify the current branch or PR #47.

- The focused download, storage, manager, provider, Downloads focus, appearance, and orphan-cleanup test set passes all 284 tests. Analyzer and translation hygiene pass, and an Android arm64 debug APK builds against the merged SDK 37 configuration.
- The latest full `scripts/ci_checks.sh` run still reports repository-wide issues: formatting drift in two legacy screens, the example WebDAV URL flagged as a hard-coded UI string, an iOS SwiftPM lock mismatch for Google Cast, 22 existing icon consistency findings, and the unused `hubIdentifierMatches` helper. Translation and native-format checks pass; the screensaver description key is restored and analyzer passes independently.
- Converted downloads and playback features still need live-server validation. Jellyfin/Emby converted streams have unknown content length and cannot resume; a failed transfer restarts from the beginning.
- New-episode notifications need Android/iOS device validation, including OS permission denial/recovery and notification behavior while the app is open. They intentionally do not claim background delivery while the app is suspended.
- Google Cast needs validation against physical receivers on both platforms. The generic receiver does not use Plex's private receiver app and cannot add custom authorization headers; server adapters therefore provide self-contained HTTP(S) URLs, and playback is limited to formats supported by the receiver.
- The live TV time-shift, local transcoding, and device-specific UI paths require real-device or server validation before release.

## Cross-media swipe discovery

The current [Find your next runtime slice](swipe/README.md) includes a bounded mixed-media deck, searchable profile-local Saved picks/history, time/medium/source/genre/mood/familiarity filters, explicit taste preferences, per-pick hide/restore/reset, capped disposable OPDS samples, exact-public-ID adaptation matching, two/three-pick comparison, private co-present voting, opt-in encrypted Saved-pick sync, optional bounded AI reranking, Open Library catalog-only candidates, and local borrower-catalog candidates when the existing OverDrive gate is enabled. Open Library does not prove local ownership or availability; borrower picks keep exact library/book identities on-device and revalidate before opening. OverDrive remains disabled by default. Feature acceptance and physical-device qualification have not run for this slice. Use the [delivery status](swipe/DELIVERY.md) as the source of truth; do not claim full device or provider qualification until real evidence is recorded.

## Planned cross-media Multiview and app-owned PiP

The [Multiview implementation handoff](multiview/README.md) makes Plezy-owned floating PiP and split views the primary cross-platform experience, with native OS PiP as an optional outside-app extension. It specifies persistent video/music/reader/game sessions, quick swaps, audio and input ownership, native/GPU/software rendering paths, portable TV readers, desktop pop-outs, accessibility and recovery. The handoff includes 22 ordered implementation packages, 64 verification scenarios, a pinned source audit and theme-based layout wireframes. This is a documentation-only plan for Luna; application implementation and device qualification remain outstanding.

## Planned service integrations and commerce

The [service integration audit and Luna handoff](service-integrations/README.md) evaluates streaming and rental services, book and audiobook stores, public libraries, music and podcasts, self-hosted sources, games, tracking and device connections. Its code now includes official storefront handoffs, Google Books public search, OpenSubsonic/Subsonic music sources and podcast RSS/Atom with OPML. The remaining account, licensed availability, DRM, affiliate and partner flows stay gated on the approvals in the work packages. Reconcile the current debrid/Stremio work and preserve those boundaries.

## Upstream sources

These authors made the linked contributions or suggestions to upstream Plezy.
Pleazyng independently adapted or reviewed the relevant behavior; the feature
status and limits above remain authoritative.

- Download quality and sync-rule ideas: [issue #1145](https://github.com/edde746/plezy/issues/1145) by [@nikwotton](https://github.com/nikwotton); [PR #1847](https://github.com/edde746/plezy/pull/1847) by [@nikwotton](https://github.com/nikwotton); [issue #1978](https://github.com/edde746/plezy/issues/1978) by [@Poag](https://github.com/Poag); [issue #2206](https://github.com/edde746/plezy/issues/2206) by [@burntcookie90](https://github.com/burntcookie90).
- Download cleanup and offline playlists: [issue #1413](https://github.com/edde746/plezy/issues/1413) by [@coyodi](https://github.com/coyodi); [issue #2181](https://github.com/edde746/plezy/issues/2181) by [@andperse](https://github.com/andperse); [issue #1721](https://github.com/edde746/plezy/issues/1721) by [@marcweigert2020](https://github.com/marcweigert2020); [issue #2600](https://github.com/edde746/plezy/issues/2600) by [@jonandeva](https://github.com/jonandeva).
- Pre-play, per-show and offset proposals: [issue #84](https://github.com/edde746/plezy/issues/84) by [@heartdeadz](https://github.com/heartdeadz); [issue #2382](https://github.com/edde746/plezy/issues/2382) by [@uaverb](https://github.com/uaverb); [PR #2346](https://github.com/edde746/plezy/pull/2346) by [@infixlabs](https://github.com/infixlabs); [PR #1956](https://github.com/edde746/plezy/pull/1956) by [@basymbhamani](https://github.com/basymbhamani).
- Subtitle styling and local import: [PR #2347](https://github.com/edde746/plezy/pull/2347) by [@infixlabs](https://github.com/infixlabs); [issue #689](https://github.com/edde746/plezy/issues/689) by [@ayydaz](https://github.com/ayydaz); [issue #1431](https://github.com/edde746/plezy/issues/1431) by [@Kuboczoch](https://github.com/Kuboczoch).
- Home composition and presentation: [PR #2203](https://github.com/edde746/plezy/pull/2203) by [@jpdexter101-lang](https://github.com/jpdexter101-lang); [issue #2690](https://github.com/edde746/plezy/issues/2690) by [@OutragedG](https://github.com/OutragedG); [PR #2723](https://github.com/edde746/plezy/pull/2723) by [@mpalermo73](https://github.com/mpalermo73); [issue #2784](https://github.com/edde746/plezy/issues/2784) by [@oliwarner](https://github.com/oliwarner).
- Profile-local protection and Explore visibility: [issue #1924](https://github.com/edde746/plezy/issues/1924) by [@jhaffey2](https://github.com/jhaffey2); [issue #2514](https://github.com/edde746/plezy/issues/2514) by [@trevorswanson](https://github.com/trevorswanson).
- Pre-rolls, theme music and equalizer proposals: [PR #2483](https://github.com/edde746/plezy/pull/2483) by [@torp93](https://github.com/torp93); [PR #2271](https://github.com/edde746/plezy/pull/2271) by [@Bergasha](https://github.com/Bergasha); [PR #2170](https://github.com/edde746/plezy/pull/2170) by [@kvart714](https://github.com/kvart714); [PR #2292](https://github.com/edde746/plezy/pull/2292) by [@whereareiam](https://github.com/whereareiam).
- Cast, foreground episode alerts and artwork screensaver requests: [issue #126](https://github.com/edde746/plezy/issues/126) by [@benfrussell](https://github.com/benfrussell); [issue #1146](https://github.com/edde746/plezy/issues/1146) by [@SquadCraftFTW](https://github.com/SquadCraftFTW); [issue #401](https://github.com/edde746/plezy/issues/401) by [@C2fifield](https://github.com/C2fifield).
- Watch links and external automation: [PR #2681](https://github.com/edde746/plezy/pull/2681) by [@razzamatazm](https://github.com/razzamatazm); [issue #823](https://github.com/edde746/plezy/issues/823) by [@Deathbot64](https://github.com/Deathbot64); [issue #1996](https://github.com/edde746/plezy/issues/1996) by [@npike](https://github.com/npike).
- Library people search and Seerr requests: [PR #2762](https://github.com/edde746/plezy/pull/2762) by [@jpdexter101-lang](https://github.com/jpdexter101-lang); [PR #2811](https://github.com/edde746/plezy/pull/2811) by [@MansiVisuals](https://github.com/MansiVisuals).
- Plex timeshift and intro-marker context: [PR #2300](https://github.com/edde746/plezy/pull/2300) by [@nullroute77](https://github.com/nullroute77); [issue #389](https://github.com/edde746/plezy/issues/389) by [@brumatheus99](https://github.com/brumatheus99); [PR #1886](https://github.com/edde746/plezy/pull/1886) by [@stuntsnakee](https://github.com/stuntsnakee).
- Log export and settings backup: [PR #2496](https://github.com/edde746/plezy/pull/2496) by [@PilaScat](https://github.com/PilaScat); [issue #1795](https://github.com/edde746/plezy/issues/1795) by [@ckravig](https://github.com/ckravig).

Related requests are not completion claims: the automation bridge is not native
Plex Companion, episode alerts are foreground-polled, and per-show preferences
do not imply the full per-library override requested upstream.

See the [full source ledger and dispositions](../../UPSTREAM_ATTRIBUTION.md).
