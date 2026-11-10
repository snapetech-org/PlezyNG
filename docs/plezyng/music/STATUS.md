# Music integration status

This is the implementation record for [PLAN.md](PLAN.md), not a completed
Plexamp-parity claim. Main contains working Dart integration and native
car adapters, but full 1:1 parity and native qualification remain incomplete.
“Existing” means retained application behavior, not a new reference comparison.
“Partial” identifies concrete remaining implementation, not just testing.

## Current continuation, 2026-11-10

Confidence is **high** for the automated results described here and **unknown**
for unperformed physical-device comparisons. Older dated verification sections
below describe their own source checkpoints, not new qualification evidence.

- Recovered main already contains acknowledged paired-device queue transfer,
  native secondary music channels, overlapping playback, and the profile-owned
  headless Linux endpoint package. These are no longer missing implementations.
- Restored Friendgänger across authorized shared music libraries; completed
  downloads can now supply revision-checked loudness analysis for offline fades.
  Duplicate playlist entries start at the selected occurrence.
- Added bounded per-profile explicit search history, separate cellular/remote
  streaming quality overrides, Favorites on the customizable home, and explicit
  Favorites/owned-download driving pickers using the same playback session.
  Numeric-only sources contribute tracks rated at least 8/10 to Favorites;
  this does not convert a favorite write into a numeric rating.
- Station retries are account/rule-qualified and separate from completed
  snapshots. Completed metadata has count/byte pruning; retry candidates survive
  pruning. Estimated storage admission budgets preserve whole albums, validate
  saved estimates, and count existing rule-linked download bytes on refresh.
  See [OFFLINE_POLICY.md](OFFLINE_POLICY.md) for admission versus final file size.
- Endpoint installation now restarts the service, propagates failed status,
  validates service paths, and preserves service files if stopping fails.
- Manual station playback now has the same source guards as downloading.
  Both Play and individual track actions reject changed authentication/accounts
  and hidden libraries. Offline previews recheck completed ownership and exact
  library identity and explicitly request offline playback, never online fallback.
- The selected music services/screens, paired provider, search and quality suite
  passed 386 tests; an additional station retry regression passed in its nine-test
  suite. Two endpoint installer tests pass, including reinstall and failure paths.
- Another 108 migration, provider-mapping, Plex audio/discovery, profile-lifecycle
  and native-player bridge tests passed. These are automated regressions, not
  reference-client or physical-device evidence.
- Seven station-preview widget regressions pass for normal online/offline
  playback and authentication, account, visibility, ownership and provenance
  changes. The canonical repository checks passed after the localization/native
  formatting corrections; those checks include isolated generation freshness,
  localization, script guards, native format, static analysis and unused-code
  scans, not hardware qualification.
- Focused Linux compilation of the application registration unit and the native
  mpv lifecycle suite passed. A separate real-libmpv test passed concurrent PCM
  decoding, separate gains, and surviving outgoing-core disposal with null audio
  output. Null output does not prove acoustic continuity or DAC behavior, and
  these focused compiles are not a full application or ARM64 package build.

The seven-area continuation connects authorized credit/edition details, native
Plex smart-playlist rules, live cursor-paged listening history, reviewed rating
conflicts and paired history reconciliation, Android and provisioned iOS
widgets/NFC, connection-bound Cast music output, and independently clocked
multi-device groups. See [PAIRING_AND_SHORTCUTS.md](PAIRING_AND_SHORTCUTS.md) for
operational scope and limits.

Remaining limits include provider/reference metadata equivalence, merged
server/local history, additional discovery controls, a RAM-independent live queue,
sender-independent Cast continuation, and reference group interoperability.
Native car artwork/provisioning and physical iPhone/Pi/car/Cast/DAC/codec and
acoustic qualification remain. No complete-parity claim is made.

- The integrated music service/screen, Cast ownership, companion provider and
  profile lifecycle suite passed **448 tests** at `e7308fcfc`, with 80 further
  migration, Plex adapter and deep-link tests. Android NFC passes focused Kotlin
  compilation and an isolated Robolectric cancellation regression. Separate
  checks cover iOS archive configuration, portable Swift widget snapshots and
  NFC bridge syntax, not signed Apple SDK builds or physical devices.

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
- Album anniversaries scan authorized album libraries with date-precision checks
  and a daily account-qualified cache. Music Audio includes an offline searchable
  catalog of 6,029 AutoEq profiles and profile-owned output EQ assignments;
  [AUTOEQ.md](AUTOEQ.md) records the pinned source, license and approximation.
- This is additional implemented scope, **not all code-level work completed**.
  Remaining discovery families and the explicit platform/group/receiver limits
  below remain code work, in addition to platform/device qualification. The
  current continuation supersedes older missing-code statements about widgets,
  NFC writing, paired synchronization, fades, transfer, budgets and the endpoint.

## Scope ledger

| ID | Feature | Implementation and remaining work | Verification |
| --- | --- | --- | --- |
| B01 | Libraries, artists, albums and tracks | Existing routes retained; discovery added to artist/album actions. Full reference comparison and huge-library device checks remain. | Artist/album screen tests pass. |
| B02 | Global and in-library search | Existing search retained; native search combines owned downloads and authorized online results. Bounded explicit recent queries are profile-owned with replay/remove/clear. Native playlists browse by server with bounded pages. Full reference parity remains. | Search/voice/history regressions pass; native assistant qualification pending. |
| B03 | Discography and album categories | Existing album/disc rendering retained; complete reference category comparison remains. | Multi-disc album regression passes. |
| B04 | Track detail, credits and editions | Account-bound metadata details expose performer/writer/producer/composer/contributor roles, labels, release dates, explicit editions and media versions without title-based recording merges. Provider/reference field completeness remains. | Role/provenance/authentication tests pass; live metadata comparison pending. |
| B05 | Ratings, favorites and listening state | Profile/account-scoped rating/favorite journal detects remote divergence before retry, acknowledges already-applied decisions, and offers explicit local/remote conflict resolution. Cold-offline rating without an account client remains. | Journal ordering, conflict revisions, already-applied retry, revocation and profile-isolation tests pass. |
| B06 | Regular playlist management | Mix previews reuse existing playlist creation. Playback starts prefer playlist occurrence IDs over media IDs. Full duplicate-aware editing, sharing and artwork parity remains. | Selected repeated-entry playback regressions pass; live playlist write pending. |
| B07 | Smart playlists and filter editing | Plex smart-playlist editor decodes native directory and server-owned rules, preserving ordered repeated parameters, exact operators, nested groups, source/result types, grouping, sort and limits. The filter form uses the rule's source kind. Server preview, create/update and save-as run under the owning account. Local station rules remain distinct. Non-Plex equivalence and live server qualification remain. | Native URI, Boolean grammar, ordered wire query and playlist regressions pass; no live permission/share claim. |
| B08 | Collections, sharing and artwork | Existing mechanisms retained; music-specific authorization and artwork completeness remain. | Not newly qualified. |
| B09 | Customizable music home | Music home is linked from Discover and Now Playing, with ordered/hidden recent, Favorites, rediscovery, anniversaries, charts, recipes, stations and download shelves. Additional reference shelf families and pins remain. | Profile persistence, Favorites source guards and 320px/200% text layout tests pass. |
| B10 | Anniversaries and rediscovery | Listening-based rediscovery and full-library album anniversaries are integrated into Music home. Anniversary scans reject incomplete/invalid dates, preserve calendar dates across timezones, page with bounded work, and cache by day/account/library revision. | History, precise-date/leap-year, pagination, cache, authorization-revocation and corrupt-pagination tests pass. |
| P01 | Gapless playback | Existing arming/transition engine retained. PCM continuity and encoder-delay fixture evidence remain. | Playback transition regressions pass; no acoustic proof. |
| P02 | Sweet Fades behavior | Two independent native decoders overlap with equal-power envelopes and session-owned handoff. Saved revision-checked analysis supports offline overlap; missing analysis keeps fallback behavior. Album exceptions remain. Reference timing/equivalence is not established. | Session handoff/cancellation/offline tests and real Linux null-output dual-core regression pass; acoustic/platform comparisons remain. |
| P03 | Loudness leveling | Music policy now selects ReplayGain track/album/automatic, disables video compression, prevents tag-based clipping and applies conservative EQ/preamp headroom. Missing tags use zero fallback. Analysis-derived absolute loudness and measured equivalence remain. | Policy/gain tests pass; acoustic measurement pending. |
| P04 | Advanced pre-caching | Complete DirectPlay files can be prefetched into a separate profile cache, with a 0–2048 MiB quota, Wi-Fi policy, total request deadline, atomic promotion, hashed credential-qualified keys and LRU eviction. Current account visibility is rechecked before promotion/use; pinned downloads are separate. Transcodes and playlists retain streaming. | Quota/LRU, malformed/partial/oversized responses, network policy, authorization revocation and clear tests pass. |
| P05 | Streaming and conversion quality | Music streaming has general, remote and cellular settings, with cellular override precedence. Music downloads retain original representation; settings and offline policy explain that distinction. Output equivalence remains. | Precedence/persistence tests pass; no new format/device matrix. |
| P06 | Queue edits, shuffle and repeat | Existing edits retained; continuation respects manual inserts, removals and clear-upcoming. Full reference gesture/Back To inventory remains. | Queue and playback tests pass. |
| P07 | Persistent large queues | Full queue, order, cursor and continuation metadata persist without a 1,000-track truncation. Listening history retains the loaded window through live database invalidation and uses keyset pages preserving repeated plays and timestamp ties. Live queue still resides in RAM and shape edits rewrite its rows. | 10,000-track persistence, duplicate occurrences, cursor paging, tied timestamps, refresh/load races and migration regressions pass. |
| P08 | Album-aware playback | Album-block shuffle/skip retained; station generation orders whole albums by disc and track, skipping blocks that exceed count/time budgets. | Album queue and station boundary tests pass. |
| P09 | Timed/plain lyrics | Authorized server lyrics are cached on explicit download and playback; per-track timing offsets affect highlighting and tap-to-seek. New data is profile-owned and rejects late revoked-account results. | Lyrics bundle, revocation and existing widget tests pass; licensed/live provider timing qualification pending. |
| P10 | Waveform/seek-print navigation | Seek-print analysis now persists in a versioned, at-most-512-sample profile document and is enriched during downloads when the selected cached source exposes Plex analysis. Unknown/invalid analysis remains absent. | Bounded bundle, stale-account and invalid-analysis tests pass; live server/device evidence pending. |
| P11 | Sleep timer | Existing timer/end-of-track behavior retained. Remote/reference-preset comparison remains. | Existing playback timer regressions pass. |
| P12 | Ten-band EQ | Dedicated music ten-band EQ, preamp, saved presets and GraphicEQ text import are connected to the real player. Imports are explicitly ten-band approximations. | Validation, headroom and import tests pass; native response measurement pending. |
| P13 | Headphone/output EQ presets | Profile-owned presets, GraphicEQ import and 6,029 searchable bundled AutoEq profiles are integrated. Output assignments apply bands/preamp when an engine route is selected and restore general EQ on other routes. Curves are explicitly ten-band approximations; physical devices hidden behind the OS auto route are not independently identified. | Output-change, removal, profile-isolation and transport-preservation tests pass; pinned dataset reproduces deterministically. Hardware response measurement remains. |
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
| D07 | Guest DJ modes | Session-owned Stretch, Gemini, Freeze, Twofer, Groupie, Contempo and Friendgänger generation added. Friendgänger interleaves bounded pools from active visible shared libraries and rechecks every source after fetching. Exact reference tuning remains. | Mode, disabled/edited/replaced queue, shared-library revocation and account/session tests pass. |
| D08 | Sonic Sage / prompt playlists | Opt-in configurable HTTPS Chat Completions provider, protected credential storage, prompt-only disclosure, strict bounded response parser, authorized exact title/artist resolution, ambiguity selection, reorder/remove, playback and playlist saving added. | Consent, redirect/size rejection, ambiguity, source-revocation and large-text tests pass; live provider interoperability pending. |
| D09 | Aural Fixations / charts | Profile track/album/artist charts use qualified listening occurrences. Explicit paired import merges original occurrence IDs and cumulative maxima. A separate paged Plex server-history view reads track events for a visible music library under verified owner credentials. Provider events lack local occurrence IDs and duration, so they are not merged into local charts or scrobbled. Managed/shared account history and reference chart equivalence remain. | Occurrence/replay, account and library filtering, pagination, stale-source rejection, chart grouping and time-window tests pass. Live Plex history qualification remains. |
| D10 | Server analysis readiness | Unsupported backend, empty results and request failure are distinct; analysis job readiness/admin controls are not implemented. | Unsupported/error contract tests pass. |
| O01 | Music downloads | Preview tracks reuse existing profile-owned download flow; existing album/playlist downloads retained. Full offline representation qualification remains. | Existing implementation reused; new live download pending. |
| O02 | Mix/station/rule downloads | Finite stations have count/time/estimated-storage budgets, whole-album mode, refresh cadence and Wi-Fi policy. Account/rule-qualified failed batches retain their original candidates and estimates outside pruned completed snapshots. Offline playback intersects current owned downloads. | Scheduler, repeated retries, account/rule revocation, storage admission and owned-snapshot tests pass. Refresh does not silently delete existing downloads or promise a hard final-size cap. |
| O03 | Full offline music experience | Existing metadata/artwork downloads are enriched with authorized lyrics and bounded analysis. Native offline search and saved-station playback reuse completed owned files. Car cold-start source added; full representation/device qualification remains. | Offline bundle/snapshot and profile tests pass. Physical no-network startup unverified. |
| O04 | Offline play/rating reconciliation | Occurrence history and serialized rating/favorite writes coexist with progress reconciliation. Offline decisions retain their original base, surface server divergence, and require a revision-qualified local/remote choice. History imports from a negotiated paired peer match portable server/account/Home-user identity and preserve event IDs; unscoped legacy events are not exported and imports never scrobble. Atomic server compare-and-set and cold-offline rating edits without a client remain. | Journal conflict/revision, history pagination/replay/rollback, account/profile revocation and stale-acknowledgement tests pass. |
| O05 | Cache/download lifecycle | Profile teardown removes owned music documents and rejects late resurrection. Disposable precache has separate quotas/LRU; completed station snapshot metadata has bounded eviction, preserving pending retries and audio files. | Migration, teardown, snapshot migration/pruning, retry preservation and download ownership regressions pass. |
| U01 | Visualizers | Existing visualizer engine retained in normal UI; driving view intentionally avoids visualizers and exposes transport plus explicit Favorites/download shortcuts. Reference controls/visual inventory remains. | Visualizer rendering/motion and driving selection/ownership tests pass. |
| U02 | Artwork backgrounds/themes | Existing styling retained; full reference reactive-theme comparison remains. | Existing Now Playing tests pass. |
| U03 | Responsive layouts | Music tools extend ordinary app routes; home, prompt and audio forms were corrected for 320px/200% text. Full desktop/tablet/TV D-pad and native packaging matrix remains. | Large-text music tools/driving tests and retained music UI regressions pass. |
| U04 | Accessibility/localization | Music-tools strings, including NFC scanning actions, have explicit base-locale text and existing regional inheritance; widget transport labels use localized shared strings. Native fallback strings and human language/screen-reader review remain. | Localization/placeholder/source checks and 320px/200% text tests pass. |
| U05 | Shortcuts/widgets/settings | Android and provisioned iOS home-screen widgets use shared profile/queue-qualified transport. Android uses process-local metadata and requires internal installation. The iOS widget uses expiring display-only snapshots and interactive controls on iOS 17+; it never restores a queue from widget data. Desktop tray/shortcut reference comparison remains. | Shared transport, portable Swift snapshot and archive configuration regressions pass; signed iOS widget and physical device qualification remain pending. |
| U06 | Links/NFC | Durable server-qualified links resolve through profile authorization, including owned offline copies. Android and provisioned iPhones support foreground reads and writes with the same token-free NDEF link contract. Native writes check tag capacity and reader ownership; foreground scans reject profile changes and extra parameters. | Dart payload/cancellation/link-validation and signing-capability regressions pass. Signed iPhone builds and physical tag qualification remain pending. |
| R01 | Chromecast music | Now Playing can select an acknowledged Cast output inside the shared session. Ownership includes the exact receiver connection and media session; loads prepare paused before authorized playback. Receiver URLs come from the active server adapter rather than local files or request headers. Queue edits, duplicate occurrences, repeat, shuffle, EOF and OS controls retain the shared queue. Takeover/disconnect returns locally paused without stopping foreign media. Native DSP/overlap is bypassed and reported absent on Cast. | Output switching, bounded acknowledgements, receiver changes, EOF/reset, takeover, auth revocation and profile lifecycle regressions pass; no live receiver/format qualification. Receiver continuation still requires the sender process. |
| R02 | AirPlay/system routes | Existing native routing retained; no general cross-platform sender added. New output diagnostics/recovery parity remains. | No new route hardware evidence. |
| R03 | Control/transfer distinction | Version-negotiated transfer sends a bounded credential-free queue snapshot; receivers validate their own source access and matching acknowledgement pauses only an unchanged sender. Transfer and paired synchronization are separate explicit actions; selecting a control target starts neither. | Snapshot/protocol/receiver/provider/Now Playing regressions pass; live paired-device qualification remains. |
| R04 | Headless Raspberry Pi | Linux ARM64 endpoint packaging, explicit headless launch mode and a managed user-service installer are present. Configure and authorize the profile normally first; virtual X11 dependencies remain. | Mode/profile and installer regressions pass; focused Linux x64 checks are not physical Pi or ARM64 package qualification. |
| R05 | Interoperability/grouping | Now Playing manages an existing control peer plus up to sixteen independently paired receivers. Each channel prepares paused, estimates monotonic clock offset/RTT, applies sequenced anchors and corrects drift above 250 ms. Per-endpoint departure leaves siblings and leader intact. Missing heartbeats, local edits and account/profile revocation retire ownership. Only the leader records progress/listens. Queue/mode replacement ends the group. Reference protocol interoperability and acoustic latency calibration remain. | Independent multi-endpoint, legacy rejection, stale connection, clock skew, replay, heartbeat, duplicate cursor and account-revocation regressions pass. No acoustic/device qualification. |
| C01 | Apple CarPlay | CarPlay lists/Now Playing share the explicit phone/headless engine; pagination updates the current template. Siri media intents use the same catalog. Entitlement activation, native artwork, native compilation and physical qualification remain. | Plist parses; Dart catalog/voice loaders pass. No new Xcode/device result claimed. |
| C02 | Android Auto | Native media browser/session retained; cold engine adds platform identity and vehicle restrictions. Warm phone engines can continue rebuilding profile state while attached to the car in background. | Dart bridge/bootstrap tests pass. New Kotlin compile and trusted-host/process-recreation qualification pending. |
| C03 | Android Automotive OS | Added a separate audio-category manifest selected by `pleazyngAutomotiveMedia`, host-rendered browsing/playback, parked setup, and media-only music allowance during restrictions. Normal distributions retain parked-only behavior. The native build attests target identity to Dart; the same profile/player/queue is reused. | Moving-vehicle music advancement and preserved video restriction tests pass. Native packaging, store acceptance and physical AAOS qualification remain. |
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

## Recovered continuation validation, 2026-11-09

The recovered branch and current-main integration pass **840** selected database,
music, car policy, profile, deep-link, scheduler, download, mpv bridge and Discover
regressions. This includes the additional prefetch/cache and AAOS media-policy
tests. The headphone picker now has an independently scrolling result list and
a large-text/keyboard selection regression. Additional native changes after the
previous Android artifact are not represented as a successful native build.
