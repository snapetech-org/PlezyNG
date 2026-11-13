# Upstream source attribution

This ledger publicly credits 93 source records: 90 from [edde746/plezy](https://github.com/edde746/plezy), one feature request from [advplyr/audiobookshelf-app](https://github.com/advplyr/audiobookshelf-app), one receiver revision from [moonlight-stream/moonlight-android](https://github.com/moonlight-stream/moonlight-android), and one compatibility fix from [superuser404notfound/AetherEngine](https://github.com/superuser404notfound/AetherEngine). They informed, supplied, or were reconciled with behavior, documentation, maintained plans, or feature context in this fork.

The linked people made their reports, suggestions, discussions, or code contributions to the upstream project. This is source credit only: it does not claim that they contributed directly to this fork, endorsed it, or participated in the fork integration. Fork maintainers adapted, integrated, or verified the resulting behavior separately.

The PR list comes from explicit “Squash of upstream” commit records and the selected November follow-up. The commit list covers follow-up changes that were sourced from upstream commits rather than PR records.

## Credited Moonlight Android source

- [Moonlight Android commit `b48494cb`](https://github.com/moonlight-stream/moonlight-android/commit/b48494cb96bff23d8886c4775cc4f39a1075495d) — pinned receiver revision (v12.2), authored upstream by [@cgutman](https://github.com/cgutman). The author contributed this receiver implementation to the upstream Moonlight project. Pleazyng independently adapted its connection, decoder, audio-renderer, input lifecycle, and retained-surface recovery for a workspace surface; this record does not claim that the author contributed to, endorsed, or participated in Pleazyng.

## Credited dependency compatibility fix

- [AetherEngine commit `fa8cc48b`](https://github.com/superuser404notfound/AetherEngine/commit/fa8cc48b93a5b9c83367bf4fb3d731fb3862a177) / [issue #883](https://github.com/superuser404notfound/AetherEngine/issues/883) — “fix(build): the package compiles on Xcode 26.3 (Swift 6.2) again,” authored and contributed to AetherEngine upstream by [@superuser404notfound](https://github.com/superuser404notfound). Pleazyng independently backports the three upstream compatibility changes to its older pinned AetherEngine source during the locked Apple runtime build; this credit does not claim a direct contribution to Pleazyng.

## Credited Audiobookshelf feature request

- [Issue #260](https://github.com/advplyr/audiobookshelf-app/issues/260), “[iOS] Auto sleep timer,” opened upstream by [@GeorgeHahn](https://github.com/GeorgeHahn). GeorgeHahn suggested automatic sleep-timer activation during certain hours to the Audiobookshelf project. Pleazyng independently adapts that idea as a profile-scoped daily local bedtime for an active audiobook session with a ten-second fade; this record does not claim direct contribution, endorsement, or participation in Pleazyng.

## Credited Plezy pull requests

Pleazyng independently integrated or adapted these upstream PRs.

- [PR #1197](https://github.com/edde746/plezy/pull/1197) — “feat(downloads): add manual sync button for sync rules,” opened upstream by [@Darkmadda](https://github.com/Darkmadda). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #1199](https://github.com/edde746/plezy/pull/1199) — “feat(downloads): random episode selection + Custom Amount (Any),” opened upstream by [@Darkmadda](https://github.com/Darkmadda). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #1516](https://github.com/edde746/plezy/pull/1516) — “feat(libraries): show item count in browse toolbar,” opened upstream by [@RyanTheTechMan](https://github.com/RyanTheTechMan). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #1584](https://github.com/edde746/plezy/pull/1584) — “feat(player): add frame-by-frame navigation,” opened upstream by [@RyanTheTechMan](https://github.com/RyanTheTechMan). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #1757](https://github.com/edde746/plezy/pull/1757) — “feat(playlist): Add reliable repeat for video playlists,” opened upstream by [@UltimateInternet](https://github.com/UltimateInternet). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2091](https://github.com/edde746/plezy/pull/2091) — “Add Emby remote subtitle search and download flow,” opened upstream by [@Bockiii](https://github.com/Bockiii). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2248](https://github.com/edde746/plezy/pull/2248) — “feat(plex): Add local-only Plex server connection,” opened upstream by [@datacompboy](https://github.com/datacompboy). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2300](https://github.com/edde746/plezy/pull/2300) — “feat(livetv): add a program-aware Plex timeshift timeline,” opened upstream by [@nullroute77](https://github.com/nullroute77). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2347](https://github.com/edde746/plezy/pull/2347) — “feat(settings): live subtitle styling preview and an RGB picker mode,” opened upstream by [@infixlabs](https://github.com/infixlabs). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2376](https://github.com/edde746/plezy/pull/2376) — “feat(downloads): show storage used and per-item download sizes,” opened upstream by [@sneakyimp1](https://github.com/sneakyimp1). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2483](https://github.com/edde746/plezy/pull/2483) — “feat(plex): play the server-configured pre-roll before movies (closes #970),” opened upstream by [@torp93](https://github.com/torp93). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2563](https://github.com/edde746/plezy/pull/2563) — “feat(plex): label versions in the picker and remember the pick across episodes,” opened upstream by [@aZuiZui](https://github.com/aZuiZui). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2596](https://github.com/edde746/plezy/pull/2596) — “feat(detail): play Plex, Jellyfin and Emby theme songs on detail pages,” opened upstream by [@crowquillx](https://github.com/crowquillx). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2597](https://github.com/edde746/plezy/pull/2597) — “feat(library): bulk select items and update watch state,” opened upstream by [@sneedster](https://github.com/sneedster). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2601](https://github.com/edde746/plezy/pull/2601) — “feat(player): add horizontal swipe-to-seek gesture on touch devices,” opened upstream by [@maf2010-boop](https://github.com/maf2010-boop). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2681](https://github.com/edde746/plezy/pull/2681) — “feat(deep-links): plezy://watch links to play a Plex show or movie,” opened upstream by [@razzamatazm](https://github.com/razzamatazm). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2725](https://github.com/edde746/plezy/pull/2725) — “Add filters to the Plex watchlist,” opened upstream by [@Supergamer1337](https://github.com/Supergamer1337). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2738](https://github.com/edde746/plezy/pull/2738) — “feat(ios): return Outplayer, Infuse and VLC to Plezy and sync their progress,” opened upstream by [@dvitjuks](https://github.com/dvitjuks). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2740](https://github.com/edde746/plezy/pull/2740) — “Add custom MDBList lists to Explore,” opened upstream by [@Adaptabull](https://github.com/Adaptabull). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2762](https://github.com/edde746/plezy/pull/2762) — “feat(detail): show directors in the cast strip and open their person page,” opened upstream by [@jpdexter101-lang](https://github.com/jpdexter101-lang). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2797](https://github.com/edde746/plezy/pull/2797) — “feat(player): add a Buffer Size setting for mpv and ExoPlayer,” opened upstream by [@BBergle](https://github.com/BBergle). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2811](https://github.com/edde746/plezy/pull/2811) — “feat(search): show Seerr titles missing from the server with a Request action,” opened upstream by [@MansiVisuals](https://github.com/MansiVisuals). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2824](https://github.com/edde746/plezy/pull/2824) — “feat(hotkeys): add subtitle delay increase/decrease shortcuts,” opened upstream by [@Rukko](https://github.com/Rukko). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2898](https://github.com/edde746/plezy/pull/2898) — “fix: Gate Plex deletes on server capability #2897,” opened upstream by [@primetime43](https://github.com/primetime43). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2938](https://github.com/edde746/plezy/pull/2938) — “fix(downloads): stop sync rules re-arming the queue after a storage refusal,” opened upstream by [@moust4ki](https://github.com/moust4ki). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2960](https://github.com/edde746/plezy/pull/2960) — “fix(plex): negotiate the selected direct-play version before opening,” opened upstream by [@nrlcode](https://github.com/nrlcode). Pleazyng independently integrated or adapted the upstream contribution.
- [PR #2971](https://github.com/edde746/plezy/pull/2971) — “feat: add PLEZY_FORCE_HDR opt-in for HDR passthrough,” opened upstream by [@Hermes-howly](https://github.com/Hermes-howly). Pleazyng independently integrated or adapted the upstream contribution.

## Credited Plezy commits

These upstream commits supplied additional implementation ideas or code to the November follow-up.

- [commit `847842c3d0`](https://github.com/edde746/plezy/commit/847842c3d075b56d686409850e12fa1cca0b19d9) — “perf(player): give mpv a constant title on iOS and tvOS (#3032),” authored upstream by [@edde746](https://github.com/edde746). The upstream author contributed the performance fix to Plezy. Pleazyng independently adapted the constant title for iOS/tvOS mpv contexts and added platform contract coverage; the upstream bench-app CPU result is not claimed as measured in Pleazyng.

- [commit `80c562ff06`](https://github.com/edde746/plezy/commit/80c562ff06db237b48592a89efb0f0b7baeb0e10) — “fix(downloads): stop the free-space guard capping desktop download speed (#2967),” authored upstream by [@edde746](https://github.com/edde746). Pleazyng independently adapted the upstream change.
- [commit `0ef47f2711`](https://github.com/edde746/plezy/commit/0ef47f2711ecb5ff30089831410b6f29b580cdcb) — “fix(tv): trigger list tile long-press from D-pad hold-select (#2964),” authored upstream by [@adamsparsons](https://github.com/adamsparsons). Pleazyng independently adapted the upstream change.
- [commit `d192a726b8`](https://github.com/edde746/plezy/commit/d192a726b8a8dd512d648f5cce9d568508d3ecd3) — “fix(downloads): exclude downloaded media from iCloud Backup on iOS,” authored upstream by [@edde746](https://github.com/edde746). Pleazyng independently adapted the upstream change.

## Planned or not-yet-shipped upstream ideas

These upstream reports informed Pleazyng’s maintained subtitle plan. They are
credited as idea sources and are not presented as completed Pleazyng features.

- [issue #689](https://github.com/edde746/plezy/issues/689) — “Add subtitle styling into player,” opened upstream by [@ayydaz](https://github.com/ayydaz). Pleazyng’s subtitle plan references this upstream idea; implementation status remains separate.
- [issue #1442](https://github.com/edde746/plezy/issues/1442) — “Subtitle Size and Position Settings Are Ignored in Some Cases,” opened upstream by [@Shasoosh](https://github.com/Shasoosh). Pleazyng’s subtitle plan references this upstream report; implementation status remains separate.

## Additional feature requests and proposals

These records were already referenced by the README feature history. Their
titles, source types and upstream authors were verified on 2026-11-09. They
record related ideas, reports and proposals, including closed or declined ones;
they do not assert that every requested behavior shipped or that a proposal
was merged upstream. Pleazyng independently adapted or reviewed the relevant
behavior. The linked feature guides remain authoritative for implementation
and qualification status. In particular, native Plex Companion control, full
per-library track preferences, delayed-deletion policies and alternate intro
providers must not be inferred from the source credit alone.

### Downloads and offline

- [issue #1145](https://github.com/edde746/plezy/issues/1145) by [@nikwotton](https://github.com/nikwotton) — Downloads Quality
- [issue #1413](https://github.com/edde746/plezy/issues/1413) by [@coyodi](https://github.com/coyodi) — Setting to automatically delete orphaned downloads
- [PR #1847](https://github.com/edde746/plezy/pull/1847) by [@nikwotton](https://github.com/nikwotton) — Add configurable Plex download quality
- [issue #1978](https://github.com/edde746/plezy/issues/1978) by [@Poag](https://github.com/Poag) — Auto download episodes on "continue watching" shelf
- [issue #2181](https://github.com/edde746/plezy/issues/2181) by [@andperse](https://github.com/andperse) — delayed delete on watch
- [issue #2206](https://github.com/edde746/plezy/issues/2206) by [@burntcookie90](https://github.com/burntcookie90) — Allow sync rules to specify quality
- [issue #1447](https://github.com/edde746/plezy/issues/1447) by [@devildant](https://github.com/devildant) — Add an offline local access mode with manually configured Plex server address
- [issue #1721](https://github.com/edde746/plezy/issues/1721) by [@marcweigert2020](https://github.com/marcweigert2020) — Download playlist to use offline, or at least enable offline queueing of downloaded music.
- [issue #2600](https://github.com/edde746/plezy/issues/2600) by [@jonandeva](https://github.com/jonandeva) — Offline Playlist

### Profiles and privacy

- [issue #1924](https://github.com/edde746/plezy/issues/1924) by [@jhaffey2](https://github.com/jhaffey2) — Require authentication before deleting downloaded media
- [issue #2514](https://github.com/edde746/plezy/issues/2514) by [@trevorswanson](https://github.com/trevorswanson) — Feature Request: Disable Explore tab per profile

### Audio and subtitle selection

- [issue #84](https://github.com/edde746/plezy/issues/84) by [@heartdeadz](https://github.com/heartdeadz) — [Feature Request]Let me choose audio track / subs BEFORE starting the video. ( like plex's native player )
- [issue #1758](https://github.com/edde746/plezy/issues/1758) by [@tr3bag](https://github.com/tr3bag) — Automatically download and select subtitles in a preferred language
- [PR #1956](https://github.com/edde746/plezy/pull/1956) by [@basymbhamani](https://github.com/basymbhamani) — fix(player): remember subtitle and audio sync offsets per media item
- [issue #2116](https://github.com/edde746/plezy/issues/2116) by [@pjakessonVS](https://github.com/pjakessonVS) — Preserve subtitle language track between episodes
- [issue #2182](https://github.com/edde746/plezy/issues/2182) by [@cthulhu7747](https://github.com/cthulhu7747) — Add Option to Choose the Audio Track Prior to Playback
- [PR #2346](https://github.com/edde746/plezy/pull/2346) by [@infixlabs](https://github.com/infixlabs) — feat(subtitles): opt-in always-on subtitles and Plex auto-download
- [issue #2382](https://github.com/edde746/plezy/issues/2382) by [@uaverb](https://github.com/uaverb) — Per-series audio track and subtitle preference override
- [issue #2792](https://github.com/edde746/plezy/issues/2792) by [@calmcacil](https://github.com/calmcacil) — Per-library overrides for preferred audio language and subtitles

### Subtitle controls and reports

- [issue #95](https://github.com/edde746/plezy/issues/95) by [@sangju41](https://github.com/sangju41) — [Feature Request] Subtitle font change
- [issue #2174](https://github.com/edde746/plezy/issues/2174) by [@saakethkaashyap](https://github.com/saakethkaashyap) — In-Player Subtitle Position and Size Controls
- [issue #1431](https://github.com/edde746/plezy/issues/1431) by [@Kuboczoch](https://github.com/Kuboczoch) — [Feature Request] Add option to load subtitles from a local file

### Playback, music and intro controls

- [issue #1985](https://github.com/edde746/plezy/issues/1985) by [@balupton](https://github.com/balupton) — Feature Request: repeat-one, repeat-all
- [issue #970](https://github.com/edde746/plezy/issues/970) by [@bart7782](https://github.com/bart7782) — Plex Preroll support
- [PR #2271](https://github.com/edde746/plezy/pull/2271) by [@Bergasha](https://github.com/Bergasha) — feat(player): play a random preroll clip before movies
- [issue #791](https://github.com/edde746/plezy/issues/791) by [@JunaidDawood](https://github.com/JunaidDawood) — TV Theme Music (Support Local Media Assets)
- [PR #2170](https://github.com/edde746/plezy/pull/2170) by [@kvart714](https://github.com/kvart714) — feat(plex): play theme music on home spotlights
- [issue #367](https://github.com/edde746/plezy/issues/367) by [@WoofGrrrr](https://github.com/WoofGrrrr) — Background play
- [PR #2292](https://github.com/edde746/plezy/pull/2292) by [@whereareiam](https://github.com/whereareiam) — feat(audio): add a device-local equalizer
- [issue #2064](https://github.com/edde746/plezy/issues/2064) by [@Kenshu0](https://github.com/Kenshu0) — Separate Quality options for remote and local streaming
- [issue #389](https://github.com/edde746/plezy/issues/389) by [@brumatheus99](https://github.com/brumatheus99) — Support for TheIntroDB API for Skip Intro/Outro Management
- [issue #1110](https://github.com/edde746/plezy/issues/1110) by [@Kida-Tech](https://github.com/Kida-Tech) — Anime skip
- [PR #1886](https://github.com/edde746/plezy/pull/1886) by [@stuntsnakee](https://github.com/stuntsnakee) — feat: Add TheIntroDB service integration for intro & recap markers

### Browsing, requests and library actions

- [issue #1517](https://github.com/edde746/plezy/issues/1517) by [@R3iniX](https://github.com/R3iniX) — Search by Actor/Director
- [issue #2368](https://github.com/edde746/plezy/issues/2368) by [@maxpowr1983-boop](https://github.com/maxpowr1983-boop) — Search for "artist/producer..."
- [issue #1561](https://github.com/edde746/plezy/issues/1561) by [@Kainton](https://github.com/Kainton) — Shuffle library
- [issue #2741](https://github.com/edde746/plezy/issues/2741) by [@fallenbuddhist](https://github.com/fallenbuddhist) — Random/Shuffle Movie Library: Plex app has this
- [issue #2757](https://github.com/edde746/plezy/issues/2757) by [@kncowans](https://github.com/kncowans) — Add the ability to Shuffle the Entire Music Library
- [issue #2671](https://github.com/edde746/plezy/issues/2671) by [@sjiawjbssj](https://github.com/sjiawjbssj) — Show "ends at" on details screen

### Home and library presentation

- [issue #1652](https://github.com/edde746/plezy/issues/1652) by [@jpdexter101-lang](https://github.com/jpdexter101-lang) — Home Screen: Merge Sections Across Multiple Libraries
- [PR #2203](https://github.com/edde746/plezy/pull/2203) by [@jpdexter101-lang](https://github.com/jpdexter101-lang) — configurable home rows: merge libraries, collection rows (#1652)
- [PR #2498](https://github.com/edde746/plezy/pull/2498) by [@PilaScat](https://github.com/PilaScat) — feat(libraries): optionally hide empty libraries
- [issue #2690](https://github.com/edde746/plezy/issues/2690) by [@OutragedG](https://github.com/OutragedG) — [Feature Request] Split next up & continue watching
- [issue #2701](https://github.com/edde746/plezy/issues/2701) by [@SilverRings11](https://github.com/SilverRings11) — Option to disable highlighted background fanart/backdrop
- [PR #2723](https://github.com/edde746/plezy/pull/2723) by [@mpalermo73](https://github.com/mpalermo73) — Make the Continue Watching row limit configurable
- [issue #2784](https://github.com/edde746/plezy/issues/2784) by [@oliwarner](https://github.com/oliwarner) — Allow hiding Hero on Android TV
- [PR #1529](https://github.com/edde746/plezy/pull/1529) by [@8bitgentleman](https://github.com/8bitgentleman) — Add a setting to choose which servers appear on Home

### Server choice and media links

- [issue #591](https://github.com/edde746/plezy/issues/591) by [@xXSalamanderXx](https://github.com/xXSalamanderXx) — Select Preferred Server / Choose Default Server / Switch Between Plex Servers
- [issue #2720](https://github.com/edde746/plezy/issues/2720) by [@wraeuk](https://github.com/wraeuk) — Set favourite plex server(s), lazyload the others

### Cast, alerts, screensaver and automation

- [issue #126](https://github.com/edde746/plezy/issues/126) by [@benfrussell](https://github.com/benfrussell) — Google Cast support
- [issue #1146](https://github.com/edde746/plezy/issues/1146) by [@SquadCraftFTW](https://github.com/SquadCraftFTW) — Notification for new episode (from official Plex app)
- [issue #401](https://github.com/edde746/plezy/issues/401) by [@C2fifield](https://github.com/C2fifield) — Feature Request: Content Screensaver
- [issue #823](https://github.com/edde746/plezy/issues/823) by [@Deathbot64](https://github.com/Deathbot64) — Control the player from external sources like Home Assistant.
- [issue #1996](https://github.com/edde746/plezy/issues/1996) by [@npike](https://github.com/npike) — Android - Intents for automation?

### Settings and diagnostics

- [PR #2496](https://github.com/edde746/plezy/pull/2496) by [@PilaScat](https://github.com/PilaScat) — feat(logs): save logs to a file
- [issue #1795](https://github.com/edde746/plezy/issues/1795) by [@ckravig](https://github.com/ckravig) — Plezy Settings Cloud Backup

## Feature inventory reference

- [Upstream README snapshot](https://github.com/edde746/plezy/blob/738e18fdc552ace910dedabf6e689ab74e1dae58/README.md), pinned at [commit `738e18fdc5`](https://github.com/edde746/plezy/commit/738e18fdc552ace910dedabf6e689ab74e1dae58), authored upstream by [@edde746](https://github.com/edde746). Pleazyng independently verified the inherited feature baseline against this upstream project snapshot for the [Plex/Plezy/Pleazyng comparison](docs/FEATURE_COMPARISON.md). This credits the upstream inventory and snapshot author; the comparison does not attribute every inherited feature to one person or claim direct participation in this fork.

## Feature documentation source footers

Feature guides link the relevant upstream records directly and link back to
this ledger for source disposition. The author links credit work or suggestions
made to Plezy; Pleazyng adaptation remains independent. A related feature
request is context, not proof that its entire scope is implemented.

_Attribution ledger refreshed 2026-11-09; see the linked per-record dispositions below._

## Music media-session integration

The music/car integration vendors the already pinned [edde746/media_controls commit a27208e](https://github.com/edde746/media_controls/commit/a27208e641790029ac54d825b97508575caee1a7), maintained by [@edde746](https://github.com/edde746), retaining its license and existing platform implementations. Pleazyng independently adds the music browser bridge. The sonic request contract was checked against [Python-PlexAPI](https://github.com/pkkid/python-plexapi)'s published `nearest` and `computePath` client implementation; no Python source was copied. Native qualification and full parity remain tracked in `docs/plezyng/music/STATUS.md`.

## Reviewed upstream synchronization — 2026-11-09

These authors contributed the changes to upstream Plezy; Pleazyng independently
adapted and verified the behavior. This does not imply direct contribution or
endorsement of this fork.

- [Shared Android Media3 FFmpeg decoder](https://github.com/edde746/plezy/commit/54a002f9b7271603d6eecba16079990dd1f83d28), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently integrated the Media3 JNI decoder and renderer with the FFmpeg libraries packaged by its Android mpv engine. The fork now resets TrueHD through FFmpeg's registered flush callback and checks the pinned FFmpeg 9 ABI.

- [Companion remote reconnect state](https://github.com/edde746/plezy/commit/e871d095171855914d8f0634b3507a80e67bedce), upstream commit by [@edde746](https://github.com/edde746): retain selected controls and scroll position during reconnect.
- [Covered-route focus handoff](https://github.com/edde746/plezy/commit/5076836a5dbb2f54b8316fdcb9d94330c1ddbf01), upstream commit by [@edde746](https://github.com/edde746): let an unfocused page above the main screen receive remote navigation.
- [Non-atomic RSS sampling regression](https://github.com/edde746/plezy/commit/55ef954e23bbcb6fac81b15a84ff7442c87c6d58), upstream commit by [@edde746](https://github.com/edde746): test independent OS counters without an unsupported ordering requirement.

- [Newly-online Continue Watching version copies](https://github.com/edde746/plezy/commit/119ce59def9eacef8ac70e2b8c0d7fdfe771e0a4), upstream commit by [@edde746](https://github.com/edde746): independently adapted to the fork, retaining its profile/transport and failed-restore retry guards.

- [Continue Watching artwork reconciliation](https://github.com/edde746/plezy/commit/f2985a7b06b1190507946cde824779880d7d2af8), upstream commit by [@edde746](https://github.com/edde746): independently adapted to the fork, retaining its profile/transport and failed-restore retry guards.

- [Late display-switch restoration](https://github.com/edde746/plezy/commit/ddcfda3c4e349ec315f1c5496a5a0e95128b6997), upstream commit by [@edde746](https://github.com/edde746): independently adapted to the fork, retaining its profile/transport and failed-restore retry guards.

- [Artwork resize debounce and resolution retention](https://github.com/edde746/plezy/commit/38c48f14ac4107cc94b2ab2f41444f0448d64da0), contributed upstream by [@strata-scribe](https://github.com/strata-scribe): Pleazyng independently integrated and verified this change, preserving its existing artwork and session behavior.

- [Watch Together guest version switching](https://github.com/edde746/plezy/commit/6c87210c6162ecaf5e9a77560353a7948e1e93bd), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently integrated and verified this change, preserving its existing artwork and session behavior.

- [Skia selection without Vulkan 1.1](https://github.com/edde746/plezy/commit/d2424018297a00fe1f8bc97ef2bb207f6a515499), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently integrated and verified this change, preserving its existing artwork and session behavior.

- [Theme-derived focus fills](https://github.com/edde746/plezy/commit/4eabc30c804c9e6869a8c48fa1d6d174f7d36fbb), upstream commit by [@edde746](https://github.com/edde746): independently adapted while preserving Pleazyng palettes, rasterized gradients and custom player chrome.

- [Light-theme scrim color interpolation](https://github.com/edde746/plezy/commit/13426a00c034097b2301967f281adbfd58381598), upstream commit by [@edde746](https://github.com/edde746): independently adapted while preserving Pleazyng palettes, rasterized gradients and custom player chrome.

- [Transparent status-bar styling](https://github.com/edde746/plezy/commit/c7f86ab85fbc2c3497676744b6b5b0b6907887d7), upstream commit by [@edde746](https://github.com/edde746): independently adapted while preserving Pleazyng palettes, rasterized gradients and custom player chrome.

- [Scoped custom video zoom](https://github.com/edde746/plezy/commit/e90973fba999838fbeb9d14b8aa8226130918be8), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently adapted zoom persistence and finite bounds, retaining profile-keyed resets and agent validation. Zoom remains session-only by default.

- [Hold playback beneath the resume profile picker](https://github.com/edde746/plezy/commit/9fe138aba39414e38099cc17cfd4296f47059778), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently adapted pause the covered player and refuse native, media-session, Watch Together and Play Next resume intents until profile selection finishes, preserving Automotive restrictions and active PiP.

- [Windows pending-resize engine correction](https://github.com/edde746/plezy/commit/90b7ccca68cffcfe51fc8994c3463fcbf769ec18), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently adapted pin the checksum-verified +2 engine for the existing Flutter ABI, retaining DirectComposition and x64/arm64 cache layouts; native Windows qualification remains separate.

- [Stable package publication metadata guard](https://github.com/edde746/plezy/commit/1dd75b3e5e95913cdaa5b8c22911490e72dfb7c5), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently adapted reject GitHub pre-releases even when their tags look like stable versions, retaining manual publication and the fork publisher.

- [System certificate authorities for GitHub asset redirects](https://github.com/edde746/plezy/commit/cbd9205f2cef71973dd7cadf568477c448cb3787), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently adapted retain system-only certificate trust through githubusercontent.com redirects on Android and dart:io, without enabling the upstream anime-feed migration.

- [Switch Android mpv display mode before decoder creation](https://github.com/edde746/plezy/commit/c577edda5cdf4b0a0c3d5dd0d543e432c5bed0d8), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently adapted hold VOD decoding at demux preload while display matching settles, bound and cancel stale holds, reject predecessor-player tokens, and retain first-frame Live TV matching, Dolby/FEL routing and motion-processing output targets.

- [Adaptive fold and vertical-bar mobile layout](https://github.com/edde746/plezy/commit/b4192d6f355921aa9dbdd89b000012e7c4496fa7), contributed upstream by [@v-vincere](https://github.com/v-vincere): Pleazyng independently adapted place navigation in the system bar, keep hosted sheets on one side of a fold and retain player ownership across route replacement; preserve the fork’s scrollable navigation and system-bar styling.

- [Sheet safe areas beside a vertical system bar](https://github.com/edde746/plezy/commit/04ec8506c78dc29b4dfc18f751943fb6ecb89eec), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently adapted remove the opposite status-bar inset and align hosted and modal sheets with the mobile content edge while retaining keyboard insets and back handling.

- [Actionable tvOS trailers and external links](https://github.com/edde746/plezy/commit/16d5b404cb14163a776b701265e55b6f66cdfc34), contributed upstream by [@moust4ki](https://github.com/moust4ki): Pleazyng independently adapted play library trailers internally, offer YouTube handoff only when its app is installed, hide unsupported browser links and report failed handoffs; preserve Seerr actions and block unsafe provider URI schemes.

- [More reliable iOS speed-change qualification](https://github.com/edde746/plezy/commit/48926474e863b8079558e41cb1d4776439ed1555), contributed upstream by [@edde746](https://github.com/edde746): Pleazyng independently adapted test the immediate position jump and the steady rate after output restarts, retaining the fork’s simulator limitation and deterministic flush-order coverage.

- [AppImage update metadata and verified zsync sidecars](https://github.com/edde746/plezy/commit/d832b4212ceabc68bfee6785177f40bd2a724723), contributed upstream by [@nataloko](https://github.com/nataloko): Pleazyng independently adapted build x64 AppImages with fork-specific update information, verify control-file names, blocks and digests, checksum and attest both artifacts, and preserve immutable legacy images without update metadata.

## Flutter security engine build (2026-11-09)

The security-engine builder uses [edde746/flutter-plezy](https://github.com/edde746/flutter-plezy/tree/06654fe6ff3fff67fdaa74e2a7c41ecbbc90bee2)'s existing Windows DirectComposition and resize patch series and build driver at immutable revision `06654fe6ff3fff67fdaa74e2a7c41ecbbc90bee2`. It applies those patches to Flutter 3.47.8 (`737ba8f885dc774b53b442759999a312c9461e4e`) with the upstream fixed Dart dependency for [GHSA-frr6-h895-5pxp](https://github.com/dart-lang/sdk/security/advisories/GHSA-frr6-h895-5pxp). The patch-source license and source revision receipt accompany the resulting archives. The orchestration script is original Pleazyng code. Built artifacts must pass verification before replacing the existing Windows engine pin.


## Complete reviewed commit dispositions — Plezy 2.26

The [64-commit review](docs/maintainers/upstream-sync-2026-11-09.md) and
[machine-readable records](docs/maintainers/upstream-sync-2026-11-09.json) link
every originating upstream commit and its upstream author's GitHub account.
Those people contributed to upstream Plezy; Pleazyng independently adapted or
verified the scope recorded there. Excluded and retained records remain review
sources, without claims of direct contribution to or endorsement of this fork.

### Native compatibility integration — packaged and verified

- [Upstream 63f8cd5a05](https://github.com/edde746/plezy/commit/63f8cd5a054e2ecc5c28dd30fe8066f4356a10c4) by [@edde746](https://github.com/edde746): Independently adapted Amlogic transparent letterboxing with the Amazon exception. Normal Android engine 6168c50b5c17 and AAR 82ace919fd97 include the native option; all four ABIs were built and inspected, and API-36 Android TV JNI read/write and playback lifecycle checks passed. Physical Dolby Vision black levels remain hardware-specific qualification.
- [Upstream 2e1654b316](https://github.com/edde746/plezy/commit/2e1654b316150f59cbc4774602ed4f02a3515527) by [@edde746](https://github.com/edde746): Independently enabled Apple MPV shader presets and ambient lighting with normal Libmpv 93fdd133cea1. All six Apple platform groups were built, every packaged architecture passed the real-stage check, and iOS/tvOS consumers linked. Real Mac M4 playback exercised hardware decoding, GLSL, stretched output and shutdown; the discovered embedded Cocoa initialization deadlock was fixed. Dolby Vision and other documented runtime exclusions remain explicit.
- [Upstream 6cc283a7da](https://github.com/edde746/plezy/commit/6cc283a7da3d75ed90ec232dd7f5da1f25681b4f) by [@edde746](https://github.com/edde746): Independently adapted the one-refresh subtitle offset for Amlogic and MediaTek TV devices after integrating early queueing and per-video-frame repetition into the normal Android/FEL engine. Scheduler, unchanged-content, rebind and runtime JNI range checks passed. Phones and unknown SoCs retain zero delay; physical TV scanout timing remains hardware-specific qualification.

The fork's native asset pins, normal FEL/HDR/NPU components and runtime opt-ins
remain intact. Upstream ancestry alone is not proof that an implementation is
active in the fork's package.

The Windows patch-source/build-driver record above originates at
[commit 06654fe6](https://github.com/edde746/flutter-plezy/commit/06654fe6ff3fff67fdaa74e2a7c41ecbbc90bee2),
contributed to the upstream engine project by [@edde746](https://github.com/edde746).
Pleazyng independently reuses that source in its security-engine orchestration;
artifact verification remains distinct from source credit.

The corresponding native changes were contributed to upstream mpv-build by
[@edde746](https://github.com/edde746):
[Apple GLSL stage](https://github.com/edde746/mpv-build/commit/2b23527),
[stretch geometry](https://github.com/edde746/mpv-build/commit/9929c5e),
[letterbox option](https://github.com/edde746/mpv-build/commit/bc87af7),
[early subtitle queue](https://github.com/edde746/mpv-build/commit/98452a9)
and [per-frame subtitle repetition](https://github.com/edde746/mpv-build/commit/8958474).
Pleazyng independently integrated and verified them with its existing normal
FEL/HDR/neural packages. This does not imply participation in or endorsement
of this fork. See the [playback compositor guide](docs/plezyng/playback-compositor.md).
