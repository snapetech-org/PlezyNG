# Music integration status

This is the implementation record for [PLAN.md](PLAN.md), not a completed
Plexamp-parity claim. The branch contains working Dart integration and native
car adapters, but full 1:1 parity and native qualification remain incomplete.
“Existing” means retained application behavior, not a new reference comparison.
“Partial” identifies concrete remaining implementation, not just testing.

## Added and connected in this branch

- Music discovery from existing artist, album and Now Playing actions: multi-seed
  mixes, sonic similarity, ordered adventure waypoints, preview, recipe editing,
  playlist creation and downloads through existing services.
- Full durable queues in database schema 36, with ordered 256-entry persistence
  batches, legacy JSON import, duplicate occurrences, shuffle order, cursor,
  continuation seed and exclusions. Saves/progress/clear are serialized.
- Rolling continuation with deduplication, manual insertion preservation,
  cancellation, replacement-session guards and bounded waiting at EOF. A pause
  while waiting prevents a delayed response from restarting audio.
- Album shuffle and skip, a server-analysis seek print beside the accessible
  slider, music-engine EQ/normalization application, and a signal-path sheet.
- One profile-scoped native catalog/command bridge; Android browsing/search uses
  the existing media session and CarPlay uses native templates. Catalog pages
  are bounded and have continuation folders. Stale queue/profile commands fail.
- A large-control driving view, manual entry and optional automatic foreground
  entry for actual projection connections. Automatic entries close on disconnect;
  attachment never starts playback, and disconnect pauses music.
- 43 new source strings translated for 32 base languages, with the existing four
  regional inheritance relationships. No additional English fallback debt.
  These translations still need native-speaker review.

## Scope ledger

| ID | Feature | Implementation and remaining work | Verification |
| --- | --- | --- | --- |
| B01 | Libraries, artists, albums and tracks | Existing routes retained; discovery added to artist/album actions. Full reference comparison and huge-library device checks remain. | Artist/album screen tests pass. |
| B02 | Global and in-library search | Existing search retained; bounded music seed search and native music search added. Reference scope/recent-query parity remains. | Request and profile-boundary tests; live search not qualified. |
| B03 | Discography and album categories | Existing album/disc rendering retained; complete reference category comparison remains. | Multi-disc album regression passes. |
| B04 | Track detail, credits and editions | Source/DSP information added; complete credits, editions and recording distinctions remain. | Static analysis; live metadata comparison pending. |
| B05 | Ratings, favorites and listening state | Existing backend-specific actions retained. Music-specific offline write/reconciliation parity remains. | No new rating qualification. |
| B06 | Regular playlist management | Mix previews reuse existing playlist creation. Full duplicate-aware editing, sharing and artwork parity remains. | Discovery generation tests; live playlist write pending. |
| B07 | Smart playlists and filter editing | Existing library filters retained. Complete music rule editor/preview/save-as remains. | Not newly qualified. |
| B08 | Collections, sharing and artwork | Existing mechanisms retained; music-specific authorization and artwork completeness remain. | Not newly qualified. |
| B09 | Customizable music home | Existing Discover/Library integration retained; dedicated configurable music shelves/pins remain. | Not newly qualified. |
| B10 | Anniversaries and rediscovery | Not added. | Pending. |
| P01 | Gapless playback | Existing arming/transition engine retained. PCM continuity and encoder-delay fixture evidence remain. | Playback transition regressions pass; no acoustic proof. |
| P02 | Sweet Fades behavior | Existing volume envelopes retained. True overlapping native playback and reference timing/album equivalence are not implemented. | Existing fade tests pass; not Sweet Fades parity. |
| P03 | Loudness leveling | Existing normalization preference now reaches the music engine. Album/track ReplayGain, peak protection and analysis-aware gain remain. | Playback suite; measured gain pending. |
| P04 | Advanced pre-caching | Existing next-source resolution retained; a new bounded byte cache and network-budget policy are not implemented. | Existing arming tests only. |
| P05 | Streaming and conversion quality | Existing source resolver/settings retained. All network/download policy distinctions and output equivalence remain. | No new format/device matrix. |
| P06 | Queue edits, shuffle and repeat | Existing edits retained; continuation respects manual inserts, removals and clear-upcoming. Full reference gesture/Back To inventory remains. | Queue and playback tests pass. |
| P07 | Persistent large queues | Full queue, order, cursor and continuation metadata persist; no 1,000-track truncation. Live queue still resides in RAM and shape edits rewrite its rows. Paged live history remains. | 10,000-track round trip, duplicate occurrences, serialized writes, legacy restore, corrupt-state rejection and v35→v36 migration pass. |
| P08 | Album-aware playback | Album-block shuffle and next-album added; server/album identity and disc/track ordering retained. Station generation still returns track-level mixes. | Album shuffle/cursor tests pass. |
| P09 | Timed/plain lyrics | Existing lyrics view retained. Offline licensed text/offset and full reference timing checks remain. | Existing music UI regressions; no new offline-lyrics implementation. |
| P10 | Waveform/seek-print navigation | Added bounded 256-bar analysis overview and click-to-seek; standard slider remains. Persistent offline analysis bundle remains. | Now Playing tests pass; server/offline/device analysis qualification pending. |
| P11 | Sleep timer | Existing timer/end-of-track behavior retained. Remote/reference-preset comparison remains. | Existing playback timer regressions pass. |
| P12 | Ten-band EQ | Existing form/preferences now applied to the music player and on setting changes. Dedicated music presets/preamp and native TV measurement remain. | Dart checks; native response measurements pending. |
| P13 | Headphone/output EQ presets | Not added. | Pending dataset provenance and implementation. |
| P14 | Sample-rate matching and DAC output | Not added; hardware output is explicitly reported as unmeasured. | No bit-perfect or output-rate claim. |
| P15 | Formats, multichannel and DSD | Existing player format support retained; full codec/channel/DSD reference matrix remains. | No new native format qualification. |
| P16 | Signal-path and quality information | Added source, transport, selected audio codec/channels, engine and configured DSP sheet. Actual hardware format and measured DSP state remain. | Static checks; hardware intentionally unknown. |
| P17 | Background playback and OS controls | Existing music session reused. Android browser can request a cached engine; headless cold-start initialization and lock-screen lifecycle require completion/qualification. | Transport regressions pass; native cold launch unverified. |
| D01 | Station/radio families | Existing instant mixes can continue automatically. Full mood/style/genre/era/library station inventory and generation modes remain. | Continuation tests pass. |
| D02 | Autoplay continuation | Added session-owned rolling tail, dedupe, exclusions, persistence, stale-work guards and EOF waiting. No independent offline recommendation generator. | Replacement, clear, manual insertion, EOF, pause and exhaustion tests pass. |
| D03 | Sonic similarity | Authorized Plex nearest requests added; exposed from integrated discovery. Independent non-Plex analysis and full reference tuning remain. | Plex request/authorization tests pass; live analyzed library pending. |
| D04 | Artist/album mix builders | Multi-seed editor, round-robin dedupe, preview, save/edit recipe, play-next, playlist and download added. Reference tuning controls and algorithm equivalence remain. | Recipe/generation tests pass. |
| D05 | Personalized mixes | Existing server mix support retained; complete personal/history shelf families remain. | No new live comparison. |
| D06 | Sonic Adventure | Ordered track waypoints, reorder controls and server computePath composition added. Shared endpoints are joined once; track-budget overflow fails instead of dropping destination. Full path constraints/equivalence remain. | Path and bounds tests pass; live server pending. |
| D07 | Guest DJ modes | Not added. | Pending mode inventory and implementation. |
| D08 | Sonic Sage / prompt playlists | Not added. | Pending provider/consent/resolution integration. |
| D09 | Aural Fixations / charts | Not added. | Pending listening-event and aggregation implementation. |
| D10 | Server analysis readiness | Unsupported backend, empty results and request failure are distinct; analysis job readiness/admin controls are not implemented. | Unsupported/error contract tests pass. |
| O01 | Music downloads | Preview tracks reuse existing profile-owned download flow; existing album/playlist downloads retained. Full offline representation qualification remains. | Existing implementation reused; new live download pending. |
| O02 | Mix/station/rule downloads | Finite preview snapshots can be downloaded. Duration/space budgets, scheduled refresh and station rules remain. | Snapshot generation tests; refresh not implemented. |
| O03 | Full offline music experience | Existing downloaded playback reused and exposed to native browsing. Full metadata/lyrics/analysis bundles and native cold start remain. | Dart browse/session tests; physical offline launch pending. |
| O04 | Offline play/rating reconciliation | Existing progress machinery retained. Music-specific idempotent events/conflicts remain. | Existing progress tests only. |
| O05 | Cache/download lifecycle | Existing ownership and storage retained. Recipe deletion is included in permanent profile/account teardown. Expanded music quotas/eviction remain. | Database/profile ownership tests; low-disk recovery pending. |
| U01 | Visualizers | Existing visualizer engine retained in normal UI; driving view has transport only. Reference controls/visual inventory remains. | Visualizer rendering/motion tests pass. |
| U02 | Artwork backgrounds/themes | Existing styling retained; full reference reactive-theme comparison remains. | Existing Now Playing tests pass. |
| U03 | Responsive layouts | New Flutter screens share ordinary app routes. Full desktop, tablet, TV D-pad and native packaging matrix remains. | Driving view tested at 320px and 200% text. |
| U04 | Accessibility/localization | Native labels use catalog text; added app strings cover all supported locales. Native fallback strings, screen-reader, RTL and human language review remain. | Localization/placeholder/source checks pass; large-text driving test passes. |
| U05 | Shortcuts/widgets/settings | Existing transport/media keys retained. New widgets/tray/one-tap shortcut parity remains. | Hardware transport regressions pass. |
| U06 | Links/NFC | No new durable music-link or NFC implementation. | Pending. |
| R01 | Chromecast music | Existing casting retained; complete music receiver queue/ownership work remains. | No new receiver qualification. |
| R02 | AirPlay/system routes | Existing native routing retained; no general cross-platform sender added. New output diagnostics/recovery parity remains. | No new route hardware evidence. |
| R03 | Control/transfer distinction | No new atomic acknowledged playback transfer. | Pending. |
| R04 | Headless Raspberry Pi | No endpoint package/installer added. | Pending. |
| R05 | Interoperability/grouping | No new synchronized grouping/protocol equivalence. | Pending. |
| C01 | Apple CarPlay | Native scene/templates and shared-session bridge added. Approved entitlement/provisioning, cold engine launch, full artwork/search/voice and device qualification remain. | Dart bridge tests and plist syntax; Xcode/device build not run. |
| C02 | Android Auto | MediaBrowserServiceCompat bridges existing MediaSessionCompat; browse pages, search and media-ID commands added. Trusted-host acceptance, headless startup and full queue/voice UX need native validation/completion. | Dart bridge tests; Android compile blocked by toolchain download access. |
| C03 | Android Automotive OS | Existing parked-only restrictions deliberately remain. Separate compliant media distribution target and moving-vehicle audio policy are not implemented. | Existing automotive restriction tests pass; no AAOS parity claim. |
| C04 | Phone driving view | Manual route plus configurable foreground entry from projection; large controls and automatic-route exit added. Favorites/offline shortcuts and selected Bluetooth car routes remain. | Narrow-screen/large-text and connection tests pass. |
| C05 | Voice commands | Android play-from-search resolves an unambiguous exact catalog title. Siri media intents and full spoken station/queue commands remain. | No native assistant qualification. |
| C06 | Car lifecycle | Connection does not autoplay; detach pauses and closes automatic phone route; stale profile/queue work is rejected. Wired/wireless, calls, process recreation and route matrix remain. | Dart connection/profile tests; physical vehicle checks pending. |
| X01 | External/retired services | Retired TIDAL is excluded from current parity. No new commercial service integration is claimed. | Scope decision, not a shipped feature. |
| X02 | Non-Plex sources | Common mix/download/playback contracts reused. Sonic capability is optional and unsupported servers remain explicit. No independent analysis added. | Backend-neutral recipe tests; provider/device parity pending. |

## Validation record

- Flutter 3.47.1 / Dart 3.13.1, pinned repository dependency versions.
- Final combined database, music service/screen/widget, Plex discovery, profile
  navigation/teardown and About regression suite: 285 tests passed after the
  main integration. The music/database-only run also passed all 274 tests.
- Canonical code generation and the isolated generated-output check passed on
  the integrated implementation; canonical generation was repeated after the
  latest main translation merge. The isolated check used archives/binaries
  verified against repository hashes to satisfy native dependencies without a
  `gh` executable.
  Localization coverage/source/placeholder
  and translation hygiene checks passed for 37 locales. Icon consistency passed.
- Android APK compilation was attempted. Flutter's pinned Android engine download
  returned proxy HTTP 403. A direct Gradle Kotlin compile also could not retrieve
  the pinned Gradle distribution (network unreachable). Neither is a successful
  native build; no dependency pins/checksum guards were weakened.
- No Xcode, Apple provisioning, CarPlay simulator, Android Auto host, AAOS vehicle,
  acoustic capture or physical DAC evidence is available from this workspace.
- Full Flutter static analysis passed with no issues. Maintained Dart source was
  formatted with the canonical formatter and the diff whitespace check passed.
  Existing CI is opt-in; opening the PR does not dispatch native builds.

## Native integration notes

See [CAR_INTEGRATION.md](CAR_INTEGRATION.md) for adapter ownership, entitlement
setup and outstanding cold-start/lifecycle work. Do not release or advertise this
branch as complete native-car support or complete Plexamp parity.

## Upstream sources

The already pinned [media-controls implementation](https://github.com/edde746/media_controls/tree/a27208e641790029ac54d825b97508575caee1a7), maintained upstream by
[@edde746](https://github.com/edde746), is vendored with its license. Pleazyng
independently extends that existing session; this is not an upstream endorsement
or direct contribution to Pleazyng. See [UPSTREAM_ATTRIBUTION.md](../../../UPSTREAM_ATTRIBUTION.md#music-media-session-integration).
