# Music integration status

This is the implementation record for [PLAN.md](PLAN.md), not a completed
Plexamp-parity claim. Main contains working Dart integration and native
car adapters, but full 1:1 parity and native qualification remain incomplete.
“Existing” means retained application behavior, not a new reference comparison.
“Partial” identifies concrete remaining implementation, not just testing.

## Added and connected on main

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

## Additional implementation in the follow-up PR

- Schema 37 adds bounded profile-owned feature documents and idempotent music
  listening occurrences. Music home, Guest DJ, charts and offline rating writes
  are initialized with the profile session, independent of a visible music page.
- Saved dynamic station rules share the library filter form and download scheduler;
  prompt playlists require explicit provider consent and resolve names locally.
- Music-specific ReplayGain, EQ/preamp, presets, buffer limits and output controls
  reach the actual audio engine. Lyrics and bounded analysis are retained with
  downloaded music; current download ownership gates offline snapshot playback.
- iOS phone/CarPlay scenes share one explicit engine. Android headless startup
  supplies device and restriction channels, and warm phone engines settle dirty
  profile builds while serving the car. Siri uses the same catalog/queue boundary.
- This is additional implemented scope, **not all code-level work completed**.
  True overlapping fades, a bounded byte cache, remaining discovery families,
  headphone datasets/automatic output mapping, music storage quotas, widgets/NFC,
  remote transfer/group synchronization, a Pi endpoint and an AAOS audio target
  remain code work, in addition to platform provisioning and device qualification.

## Scope ledger

| ID | Feature | Implementation and remaining work | Verification |
| --- | --- | --- | --- |
| B01 | Libraries, artists, albums and tracks | Existing routes retained; discovery added to artist/album actions. Full reference comparison and huge-library device checks remain. | Artist/album screen tests pass. |
| B02 | Global and in-library search | Existing search retained; native search combines owned downloads and authorized online results. Native playlists browse by server with bounded pages. Full recent-query/reference parity remains. | Search/voice reject ambiguous names and stale account results; native assistant qualification pending. |
| B03 | Discography and album categories | Existing album/disc rendering retained; complete reference category comparison remains. | Multi-disc album regression passes. |
| B04 | Track detail, credits and editions | Source/DSP information added; complete credits, editions and recording distinctions remain. | Static analysis; live metadata comparison pending. |
| B05 | Ratings, favorites and listening state | Profile/account-scoped idempotent rating/favorite journal, reconnect retry and pending-write feedback added to the existing action sheet. Cold-offline rating without an account client and cross-device conflict reconciliation remain. | Journal ordering, acknowledgement, revocation and profile-isolation tests pass. |
| B06 | Regular playlist management | Mix previews reuse existing playlist creation. Full duplicate-aware editing, sharing and artwork parity remains. | Discovery generation tests; live playlist write pending. |
| B07 | Smart playlists and filter editing | Saved dynamic station rules reuse the existing filter editor, sort, count/time budgets, whole albums and preview. These remain explicit local rules, not falsely advertised server smart playlists. Full server smart-playlist write/share semantics remain. | Rule serialization, cancellation, unknown-filter rejection, deduplication and album-budget tests pass. |
| B08 | Collections, sharing and artwork | Existing mechanisms retained; music-specific authorization and artwork completeness remain. | Not newly qualified. |
| B09 | Customizable music home | Music home is linked from Discover and Now Playing, with ordered/hidden recent, rediscovery, charts, recipes, stations and download shelves. Additional reference shelf families and pins remain. | Profile persistence and 320px/200% text layout tests pass. |
| B10 | Anniversaries and rediscovery | Listening-based rediscovery of tracks last heard more than 90 days ago added. Full-library album anniversary generation with date-precision handling remains. | History aggregation and rediscovery cutoff tests pass. |
| P01 | Gapless playback | Existing arming/transition engine retained. PCM continuity and encoder-delay fixture evidence remain. | Playback transition regressions pass; no acoustic proof. |
| P02 | Sweet Fades behavior | Existing volume envelopes retained. True overlapping native playback and reference timing/album equivalence are not implemented. | Existing fade tests pass; not Sweet Fades parity. |
| P03 | Loudness leveling | Music policy now selects ReplayGain track/album/automatic, disables video compression, prevents tag-based clipping and applies conservative EQ/preamp headroom. Missing tags use zero fallback. Analysis-derived absolute loudness and measured equivalence remain. | Policy/gain tests pass; acoustic measurement pending. |
| P04 | Advanced pre-caching | Existing next-source resolution retained; a new bounded byte cache and network-budget policy are not implemented. | Existing arming tests only. |
| P05 | Streaming and conversion quality | Existing source resolver/settings retained. All network/download policy distinctions and output equivalence remain. | No new format/device matrix. |
| P06 | Queue edits, shuffle and repeat | Existing edits retained; continuation respects manual inserts, removals and clear-upcoming. Full reference gesture/Back To inventory remains. | Queue and playback tests pass. |
| P07 | Persistent large queues | Full queue, order, cursor and continuation metadata persist; no 1,000-track truncation. Live queue still resides in RAM and shape edits rewrite its rows. Paged live history remains. | 10,000-track round trip, duplicate occurrences, serialized writes, legacy restore, corrupt-state rejection and v35→v36 migration pass. |
| P08 | Album-aware playback | Album-block shuffle/skip retained; station generation orders whole albums by disc and track, skipping blocks that exceed count/time budgets. | Album queue and station boundary tests pass. |
| P09 | Timed/plain lyrics | Authorized server lyrics are cached on explicit download and playback; per-track timing offsets affect highlighting and tap-to-seek. New data is profile-owned and rejects late revoked-account results. | Lyrics bundle, revocation and existing widget tests pass; licensed/live provider timing qualification pending. |
| P10 | Waveform/seek-print navigation | Seek-print analysis now persists in a versioned, at-most-512-sample profile document and is enriched during downloads when the selected cached source exposes Plex analysis. Unknown/invalid analysis remains absent. | Bounded bundle, stale-account and invalid-analysis tests pass; live server/device evidence pending. |
| P11 | Sleep timer | Existing timer/end-of-track behavior retained. Remote/reference-preset comparison remains. | Existing playback timer regressions pass. |
| P12 | Ten-band EQ | Dedicated music ten-band EQ, preamp, saved presets and GraphicEQ text import are connected to the real player. Imports are explicitly ten-band approximations. | Validation, headroom and import tests pass; native response measurement pending. |
| P13 | Headphone/output EQ presets | Profile-owned named EQ presets and user-supplied GraphicEQ import added. Searchable bundled headphone dataset, provenance and automatic per-output assignment remain. | Preset serialization/import tests pass; no dataset-equivalence claim. |
| P14 | Sample-rate matching and DAC output | Explicit engine sample-rate, exclusive-output and device preferences added, with absent-device fallback to automatic output. Actual DAC matching and bit-perfect qualification remain; iOS retains nonmixing media-session behavior. | Engine policy and unplugged-output tests pass; hardware format remains unmeasured. |
| P15 | Formats, multichannel and DSD | Existing player format support retained; full codec/channel/DSD reference matrix remains. | No new native format qualification. |
| P16 | Signal-path and quality information | Signal-path sheet reads native decoder/output rate, channels, format, engine device and DSP properties. It separately identifies hardware output as unmeasured. | Dart analysis and policy tests pass; physical output evidence pending. |
| P17 | Background playback and OS controls | Android cold car startup registers engine-only device/restriction handlers and uses normal profile bootstrap. iOS phone and CarPlay share an explicit headless-capable engine. Background dirty builds can settle without a visible phone frame. | Background scheduling and profile lifecycle regressions pass. New Kotlin/Swift sources still require native compilation and device qualification. |
| D01 | Station/radio families | Saved dynamic stations expose supported server genre/mood/style/year filters through the existing editor, sort/count/time limits and album blocks. Native catalog includes saved stations and server audio playlists. Complete preset station-family/reference behavior remains. | Rule and native playlist loader tests pass; live provider comparison pending. |
| D02 | Autoplay continuation | Added session-owned rolling tail, dedupe, exclusions, persistence, stale-work guards and EOF waiting. No independent offline recommendation generator. | Replacement, clear, manual insertion, EOF, pause and exhaustion tests pass. |
| D03 | Sonic similarity | Authorized Plex nearest requests added; exposed from integrated discovery. Independent non-Plex analysis and full reference tuning remain. | Plex request/authorization tests pass; live analyzed library pending. |
| D04 | Artist/album mix builders | Multi-seed editor, round-robin dedupe, preview, save/edit recipe, play-next, playlist and download added. Reference tuning controls and algorithm equivalence remain. | Recipe/generation tests pass. |
| D05 | Personalized mixes | Device-local recent, rediscovery and period chart shelves added alongside existing server mixes. Complete personalized/reference mix families remain. | History/profile/layout tests pass. |
| D06 | Sonic Adventure | Ordered track waypoints, reorder controls and server computePath composition added. Shared endpoints are joined once; track-budget overflow fails instead of dropping destination. Full path constraints/equivalence remain. | Path and bounds tests pass; live server pending. |
| D07 | Guest DJ modes | Session-owned Stretch, Gemini, Freeze, Twofer, Groupie and Contempo generation added, with generated labels, mode-off cleanup, queue-edit cancellation and authenticated source guards. Friendgänger and exact reference tuning remain. | Mode, disabled/edited/replaced queue, stale response and server-scope tests pass. |
| D08 | Sonic Sage / prompt playlists | Opt-in configurable HTTPS Chat Completions provider, protected credential storage, prompt-only disclosure, strict bounded response parser, authorized exact title/artist resolution, ambiguity selection, reorder/remove, playback and playlist saving added. | Consent, redirect/size rejection, ambiguity, source-revocation and large-text tests pass; live provider interoperability pending. |
| D09 | Aural Fixations / charts | Cumulative occurrence-based listening events, seek/pause exclusion, qualification threshold and local track/album/artist charts for 7/30/365/all days added. Counts are explicitly device-local. Server-wide/device history import and full Aural Fixations parity remain. | Occurrence, idempotence, seek exclusion, chart grouping and time-window tests pass. |
| D10 | Server analysis readiness | Unsupported backend, empty results and request failure are distinct; analysis job readiness/admin controls are not implemented. | Unsupported/error contract tests pass. |
| O01 | Music downloads | Preview tracks reuse existing profile-owned download flow; existing album/playlist downloads retained. Full offline representation qualification remains. | Existing implementation reused; new live download pending. |
| O02 | Mix/station/rule downloads | Finite stations have count/time budgets, whole-album mode, refresh cadence and Wi-Fi policy through existing sync rules. Failed queue batches retain the same pending snapshot. Offline playback intersects snapshots with current owned downloads. Space quotas and automatic snapshot pruning remain. | Station scheduler, cooldown, profile/rule change and owned-snapshot tests pass. Refresh intentionally does not silently delete existing downloads. |
| O03 | Full offline music experience | Existing metadata/artwork downloads are enriched with authorized lyrics and bounded analysis. Native offline search and saved-station playback reuse completed owned files. Car cold-start source added; full representation/device qualification remains. | Offline bundle/snapshot and profile tests pass. Physical no-network startup unverified. |
| O04 | Offline play/rating reconciliation | New local music history and serialized idempotent rating/favorite setters coexist with existing progress reconciliation. Cross-device conflict resolution and cold-offline edits without a client remain. | Journal revision, auth-scope, retry and stale-acknowledgement tests pass. |
| O05 | Cache/download lifecycle | History, documents, recipes, snapshots and pending edits are deleted on permanent profile teardown; epochs reject late resurrection. Existing download ownership/storage retained. Disposable precache quotas and music snapshot eviction remain. | Schema 37 migration, teardown/late-write and download-ownership regressions pass. |
| U01 | Visualizers | Existing visualizer engine retained in normal UI; driving view has transport only. Reference controls/visual inventory remains. | Visualizer rendering/motion tests pass. |
| U02 | Artwork backgrounds/themes | Existing styling retained; full reference reactive-theme comparison remains. | Existing Now Playing tests pass. |
| U03 | Responsive layouts | Music tools extend ordinary app routes; home, prompt and audio forms were corrected for 320px/200% text. Full desktop/tablet/TV D-pad and native packaging matrix remains. | Large-text music tools/driving tests and retained music UI regressions pass. |
| U04 | Accessibility/localization | All 23 new music-tools strings have explicit base-locale text and the existing regional inheritance; native fallback strings and human language/screen-reader review remain. | Localization/placeholder/source checks and 320px/200% text tests pass after correcting an empty reused recent-label translation. |
| U05 | Shortcuts/widgets/settings | Existing transport/media keys retained. New widgets/tray/one-tap shortcut parity remains. | Hardware transport regressions pass. |
| U06 | Links/NFC | Durable server-qualified music links now resolve track/album/artist selections through existing deep links and profile authorization, including owned offline copies. NFC writing remains. | Music deep-link parsing/launching regressions pass. |
| R01 | Chromecast music | Existing casting retained; complete music receiver queue/ownership work remains. | No new receiver qualification. |
| R02 | AirPlay/system routes | Existing native routing retained; no general cross-platform sender added. New output diagnostics/recovery parity remains. | No new route hardware evidence. |
| R03 | Control/transfer distinction | No new atomic acknowledged playback transfer. | Pending. |
| R04 | Headless Raspberry Pi | No endpoint package/installer added. | Pending. |
| R05 | Interoperability/grouping | No new synchronized grouping/protocol equivalence. | Pending. |
| C01 | Apple CarPlay | CarPlay lists/Now Playing share the explicit phone/headless engine; pagination updates the current template. Siri media intents use the same catalog. Entitlement activation, native artwork, native compilation and physical qualification remain. | Plist parses; Dart catalog/voice loaders pass. No new Xcode/device result claimed. |
| C02 | Android Auto | Native media browser/session retained; cold engine adds platform identity and vehicle restrictions. Warm phone engines can continue rebuilding profile state while attached to the car in background. | Dart bridge/bootstrap tests pass. New Kotlin compile and trusted-host/process-recreation qualification pending. |
| C03 | Android Automotive OS | Existing parked-only restrictions deliberately remain. Separate compliant media distribution target and moving-vehicle audio policy are not implemented. | Existing automotive restriction tests pass; no AAOS parity claim. |
| C04 | Phone driving view | Manual route plus configurable foreground entry from projection; large controls and automatic-route exit added. Favorites/offline shortcuts and selected Bluetooth car routes remain. | Narrow-screen/large-text and connection tests pass. |
| C05 | Voice commands | Siri INPlayMediaIntent resolution/confirmation/handling added for exact track/artist/album and named saved station/recipe, with shuffle/repeat and next/later. Native server playlist browsing and selection use the existing authorized API. Ambiguity requires selection. | Catalog playlist expansion and stale-auth tests pass. Native Siri/Android assistant tests remain. |
| C06 | Car lifecycle | Connection never autoplays; detach pauses/closes automatic route. Session-scoped opaque IDs and queue-shape revisions reject stale commands. Cold/warm engine boot retains profile/PIN and AAOS restriction gates. | Dart connection/profile/background tests pass; wired/wireless, interruption and physical vehicle matrix remain. |
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
setup and cold-start implementation and outstanding native/lifecycle qualification. Do not release or advertise this
implementation as complete native-car support or complete Plexamp parity.

## Upstream sources

The already pinned [media-controls implementation](https://github.com/edde746/media_controls/tree/a27208e641790029ac54d825b97508575caee1a7), maintained upstream by
[@edde746](https://github.com/edde746), is vendored with its license. Pleazyng
independently extends that existing session; this is not an upstream endorsement
or direct contribution to Pleazyng. See [UPSTREAM_ATTRIBUTION.md](../../../UPSTREAM_ATTRIBUTION.md#music-media-session-integration).

## Earlier main integration verification, 2026-11-09 (before this follow-up)

Integrated by merge with the current application/security tree, retained the Android
isolated-core broker alongside engine reuse, and regenerated canonical outputs.
The merged tree passes all 285 selected database/music/profile/About regressions,
full Flutter analysis, maintained-source formatting, localization/translation
checks and isolated generation freshness. The first canonical Android attempt stopped at a pre-existing stale shared
Moonlight source cache, which was preserved. A fresh isolated checkout then
passed the full application Kotlin compile and assembled the current-main
3.0.19 debug APK (source `74e8d63d2`). Package checks pass for the actual Flutter
ABIs arm64-v8a, armeabi-v7a and x86_64, including receiver/worker exports, source
receipts and 16 KiB alignment. These compile/package results do not establish
Android Auto host behavior or native-car device qualification.

## Follow-up validation, 2026-11-09

The changes above are rebased by merge onto main `a3d0261`. The earlier 285-test
and Android APK evidence describes the previous integration, not the additional
engine/intent/plugin sources in this follow-up. The selected merged regression suite passes **656 tests**, covering database
migrations/ownership, music playback/services/screens/widgets, profile sessions,
deep links, rating actions, download providers/screens and station scheduling.
Full Flutter analysis reports no issues; canonical Dart formatting, localization
coverage/placeholders/source hashes, translation hygiene and icon checks pass.
Pinned ktlint 1.5.0 formatting/checking passes for all three changed Kotlin files.
Canonical generation and the isolated freshness check pass. Info.plist parses
successfully. Ten focused car tests also pass after adding default automatic
entry, preserved opt-out, disconnect removal, already-dirty background wake-up
and catalog-membership refresh coverage. Attachment still never starts audio.

The new Android build attempt obtained the Flutter engine artifacts but stopped
before native compilation: Java could not reach the pinned Gradle distribution
(`Network is unreachable`). Toolchain pins/checksums were retained. Xcode and
Swift compilation/formatting are unavailable in this Linux workspace. No native/vehicle/DAC result is
inferred from Dart tests, plist parsing or source registration.
