# Music integration status

This is the implementation record for [PLAN.md](PLAN.md), not a completed
Plexamp-parity claim. Main contains working Dart integration and native
car adapters, but full 1:1 parity and native qualification remain incomplete.
“Existing” means retained application behavior, not a new reference comparison.
“Partial” identifies concrete remaining implementation, not just testing.

## Personal history, offline ratings and receiver recovery, 2026-11-10

The following tested slices were pushed individually to main:

- `039f2e632`: managed/shared Plex personal history through the active user
  token, with numeric account pinning and mixed-account rejection. The separate
  owner-only permission for requesting audio analysis is unchanged.
- `f5a63359c`: cold-start rating intents use unique persisted profile/account
  bindings before clients exist. Reconnection compares the original remote
  base. `78ba41ab4` preserves the exact saved MediaBrowser namespace as well.
- `a3f572d45`: detached Cast control recovers from a bounded profile-owned
  document only when the receiver session, acknowledged media session, owner
  token, occurrence and account scopes match. Recovery stores no stream URLs
  and does not reload or autoplay the receiver.
- `d1dee5b78`: native Caldera/Plexamp group control is reachable from music
  synchronization, with multicast/manual discovery, versioned state, grouping,
  transport and volume. Native players retain their existing queues and clocks.

Validation: **494 music/integration tests** and **125 server/companion-provider
tests** passed. The final account-namespace correction passed **17 focused
rating tests**. The complete `scripts/ci_checks.sh` gate subsequently passed,
including codegen, localization, formatting, workflow guards, analyzer, icon and
unused-code/file checks. These are automated results, not physical-device
qualification.

## Native group audio continuation, 2026-11-11

Pleazyng can explicitly receive native Xita audio through the shared player,
and send its shared queue to selected native speakers. The verified wire
contract uses Zita framing, fixed native membership port 5000, acknowledged
mesh membership and monotonic frame-clock mapping. Source output retains the
queue, overlapping decoders and listen authority; profile/account retirement
releases capture and restores the prior local mute. Receive state now follows
source track/artist/album and progress; shared controls forward to the separately
verified Companion playback identity. Paused/suspended membership remains open
with silence and resumes on a fresh frame timeline. State subscriptions have
per-event bounds and retire with the owning source/account. The combined native
group, clock, bridge, controller and shared-player suite passes 275 tests.

Confidence is **high** for protocol and automated code results. The official
Caldera 1.1.0 reference accepted both directions in isolated generated-audio
runs: receive supplied 160,652 WAV bytes; the production transmitter supplied
718 packets with zero packet drops. Native capture/fan-out passes C++17/C++20
tests and the changed Linux wrappers compile. Source integration passed 116
focused tests. These observations do not establish acoustic synchronization.

Explicit profile-lifetime native availability now advertises a stable endpoint
and accepts incoming source/sink membership, resolving known private peers and
coalescing replaceable setup operations. The official Caldera reference
discovered this endpoint and initiated both directions: 76,800 source frames
and 176,540 received WAV bytes were observed. Availability opens no decoder by
itself, is off by default, and closes with the account/client set. Adding/removing speakers now retains
the capture lease, source UDP port and frame clock. Failed/cancelled additions
preserve existing outputs and one peer departure leaves siblings playing.
Two official receivers exercised native-initiated changes with 613/686 packets,
zero drops and one uninterrupted 120,960-frame capture lease.
Native per-player volume relays now use bounded serial shared controls on
hosted and dedicated audio connections, rechecking queued ownership and retaining
audio/queue state. Receiver gain remains local. The official controller applied
37 through its native relay; 139 focused tests pass.
Native enable/gain/band EQ relays now compose at execution time through the
shared music session, persist bounded profile settings and publish accepted state.
Receiver EQ stays local; a transmitting source excludes this per-speaker layer
from wire PCM. Rejected changes roll back, and an unsupported restored preset
reports an error without preventing ordinary music playback. The combined
volume/EQ/mesh/player suite passes 227 tests. An official Caldera controller
applied enable, -3.5 dB gain and two exact bands to the production host.
Actual pinned Linux execution found missing FFmpeg EQ filters. Producer repair
eb78e98 now builds and executes generated flat/peak/shelf/global-gain PCM checks
successfully on the rebuilt Linux binary. Producer 3e674d64a821 now publishes
verified Apple, Android, Linux and Windows artifacts, and every application pin
and verification receipt moves to that revision together. Both Linux architectures
passed actual DSP execution. All six Apple targets passed native builds; assembly
and Objective-C-only iOS/tvOS SwiftPM link checks passed before immutable publication.
The Android ARM64 debug application compiles from 740e2df28 with these native pins.
Application builds on other platforms and physical output qualification remain separate.
Native source output now negotiates saved audio.channels preferences with bounded,
non-redirecting reads and preserves stereo for automatic or legacy peers.
Known 5.1/7.1 capture is canonicalized; stereo/5.1/7.1 buses advance on one clock
with layout-matched, MTU-bounded packets. Changed/invalid preferences retire only
that peer. 307 combined format/mixer/source/membership/mesh/clock/player tests and
C++17/C++20 native capture tests pass. Official Caldera 1.1.0 receivers confirmed
6/8-channel production wire audio, receiving 1,608/2,053 packets with zero drops.
The preference reflects saved configuration, not a launch-only channel override.
Physical output-latency qualification remains.
Local physical-output/headphone correction is now excluded from wire PCM while
retaining the general source curve. Leaving restores the latest saved output
preset without changing queue ownership; 113 focused output/shared-session
tests pass. The full Linux debug application compiles at a64e31c8b with the
pinned MilkRust runtime. The full Android ARM64 debug application also compiles at 2144d0300; Apple application builds and acoustic evidence remain.
 Renderer
feedback now reads the current core's audible audio-PTS, maps its WAV clock to
monotonic time and resamples source frames for actual presentation. Bounded
output priming, drift/phase correction and stale-clock retirement have automated
coverage, including delay/impulse simulations and clocked socket playback.
Known-format WAV startup disables multi-second probing and caps pre-clock
silence at 100 ms. The actual pinned Linux decoder rendered a scheduled generated
pulse through a timed null output within 15 ms; this is not acoustic qualification. Known
multichannel decoder layouts now preserve canonical 5.1/7.1 or fold into the
stereo group bus without changing visualizer PCM; speaker routing and invalid-data regressions pass in both native
language modes. Selected
peers can now fetch bounded source metadata and control the shared queue through
a target-qualified, replay-protected Companion endpoint. The current binary
lock already contains the ordered PCM ABI on every platform; the pinned Linux
archive checksum and four tap exports were verified. Generated tone execution
against that actual library now also verifies capture while muted, cubic AO
volume and tagged ReplayGain. Music fades/headroom preserve linear gain under
the native volume curve; transmitted PCM reapplies native AO gain once, updates
queued lane gain immediately and rejects late decoder results. The earlier promotion
warning was stale. Physical speakers and platform builds still need qualification. Full parity is incomplete.

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
unbounded or repeating standalone Cast queues, and native group device/acoustic qualification.
Native car artwork/provisioning and physical iPhone/Pi/car/Cast/DAC/codec and
acoustic qualification remain. No complete-parity claim is made.

- The integrated music service/screen, Cast ownership, companion provider and
  profile lifecycle suite passed **448 tests** at `e7308fcfc`, with 80 further
  migration, Plex adapter and deep-link tests. Android NFC passes focused Kotlin
  compilation and an isolated Robolectric cancellation regression. Separate
  checks cover iOS archive configuration, portable Swift widget snapshots and
  NFC bridge syntax, not signed Apple SDK builds or physical devices.
- The next integrated run passed **554 tests** at `222d97ae8`, including verified
  Plex owner history, scoped rolling mixes, album-aware fades, station presets,
  and Cast queue handoff and return. The canonical repository checks passed at
  that checkpoint. The subsequent metadata and Cast stop changes passed their
  focused regressions; 19 reconciliation tests passed after the rating conflict
  revision fix. These results do not add live server or device qualification.
- The same integrated suite passed **556 tests** at `e8a329f06`, including the
  final credit, Cast stop and rating conflict changes. The maintained Dart
  formatter, targeted fatal-info analysis and diff check also passed for those
  changes. The full repository gate result above is from `222d97ae8`.

## Play on a device, 2026-11-11

The shared Play on picker is available from Music home, Now Playing and the
mini-player. It connects nearby and remembered paired receivers, exposes
receiver setup and Cast, and returns a receiver-owned session to this device.
Modern handoff supports 4,096 queue occurrences and bounded chunked messages.
Plex account, direct Plex, Jellyfin and Emby profiles share this path.

Receiver revision checks, prepare/freeze/commit, replay-safe receipts and
uncertain-result reconciliation preserve ownership. Normal player and queue
controls address the selected receiver. Optional music-only E2E relay clients
use outbound connections, encrypted invitations and automatic active-controller
reconnection. The Go route includes admission, bandwidth and queue limits.

See [Play on](PLAY_ON.md) for setup and limits and
[relay deployment](../../../server/MUSIC_CONNECT.md) for service activation.
At `dedb73b`, both focused encrypted-loopback preflight checks and all 546
integrated tests passed. The complete Go server suite passed with the race
detector. Relay activation, app-release distribution, hardware qualification
and native-language review remain open.

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
| B04 | Track detail, credits and editions | Account-bound metadata details expose performer/writer/producer/composer/contributor roles, labels, release dates, explicit editions and audio versions with codec and channel layouts. Album titles are never treated as a track's performer; similarly titled recordings stay separate. Provider/reference field completeness remains. | Role/provenance/authentication tests pass; live metadata comparison pending. |
| B05 | Ratings, favorites and listening state | Profile/account-scoped rating/favorite journal detects remote divergence before retry, acknowledges already-applied decisions, and offers explicit local/remote conflict resolution. A further remote change during resolution replaces the displayed conflict and rejects either choice from the older revision. Cold-offline edits resolve a unique saved profile/account binding before a runtime client exists; live replay still requires the same scope. | Journal ordering, repeated remote changes, conflict revisions, already-applied retry, revocation and profile-isolation tests pass. |
| B06 | Regular playlist management | Creation and occurrence-aware playback, reorder and removal use existing playlist endpoints. Plex regular and smart playlist titles/summaries can be edited from detail with fresh metadata, changed-field writes, observed conflict detection and account/route retirement guards. Browse refresh follows accepted edits. Regular audio playlists offer occurrence-aware multi-selection and confirmed removal, with fresh paged preflight, serialized writes, account retirement and authoritative recovery before explicit retries. Deletion confirmations and single-entry acknowledgements also retire with the owning route/account; accepted moves/removals refresh browse callers. Plex artwork selection, bounded image upload and default restoration are reachable from detail with fresh server choices, first-frame validation, frozen request payloads and account/route guards. Sharing parity remains. | Playlist API, editor/route, multi-selection, retirement and Plex/Jellyfin/Emby batch regressions pass; live permission and write qualification remains. |
| B07 | Smart playlists and filter editing | Plex smart-playlist editor decodes native directory and server-owned rules, preserving ordered repeated parameters, exact operators, nested groups, source/result types, grouping, sort and limits. The filter form uses the rule's source kind. Server preview, create/update and save-as run under the owning account. Local station rules remain distinct. Non-Plex equivalence and live server qualification remain. | Native URI, Boolean grammar, ordered wire query and playlist regressions pass; no live permission/share claim. |
| B08 | Collections, sharing and artwork | Collection destinations, member removal and deletion require the current owner/admin and a stable profile, authentication session, account, server and library visibility. Shared users retain personal playlists and browsing. Collection detail and context menus now edit title, sort title, summary, poster and background through the existing metadata editor, with collection type 18 and square Plex artist/album artwork. Text/image picker decisions and late acknowledgements retain the original authorization scope; shared menus also hide collection deletion. Music collection creation and membership entry points remain to be integrated. | 133 collection/menu, metadata/artwork and authorization regressions pass, including replaced accounts during removal/deletion confirmations and stale text/image decisions; device/live-server behavior is not newly qualified. |
| B09 | Customizable music home | Music home is linked from Discover and Now Playing, with ordered/hidden server recommendations, recent, Favorites, rediscovery, anniversaries, charts, recipes, stations and download shelves. A bounded, account-owned pinned-music shelf supports artists, albums and tracks, with fresh authorization on save/open and removal/order controls. Server recommendation previews retain the server-authored family/title, read only visible online music libraries, and bound parallel sources, shelves and rows. Retained results and actions retire with profile binding, library visibility, authentication or account changes. Additional reference shelf comparison remains. | Profile persistence, Favorites source guards, pin storage/isolation and live shelf/editing tests pass, including 320px/200% text layouts. Recommendation regressions cover provenance, fairness and budgets, degraded providers, profile/PIN retirement and account changes during album expansion. |
| B10 | Anniversaries and rediscovery | Listening-based rediscovery and full-library album anniversaries are integrated into Music home. Anniversary scans reject incomplete/invalid dates, preserve calendar dates across timezones, page with bounded work, and cache by day/account/library revision. | History, precise-date/leap-year, pagination, cache, authorization-revocation and corrupt-pagination tests pass. |
| P01 | Gapless playback | Existing arming/transition engine retained. PCM continuity and encoder-delay fixture evidence remain. | Playback transition regressions pass; no acoustic proof. |
| P02 | Sweet Fades behavior | Two independent native decoders overlap with equal-power envelopes and session-owned handoff. Saved revision-checked analysis supports offline overlap. Unshuffled queues that match ordered album metadata retain gapless playback, including when launched from a playlist. Queue edits re-evaluate the rule. Reference timing/equivalence is not established. | Session handoff/cancellation/offline, album-order and queue-edit tests and real Linux null-output dual-core regression pass; acoustic/platform comparisons remain. |
| P03 | Loudness leveling | Track/album/automatic ReplayGain now carries explicit Plex server gain and linear peaks into file-local options for offline, cached, gapless and overlapping playback. Native tags take precedence; bounded analysis fallback prevents peak clipping, unknown peaks cannot amplify, and missing analysis stays at zero. Mode/shuffle changes update current and armed entries. EQ/preamp headroom and disabled video compression remain. | Policy, parser, native bridge and shared-player suites pass. Six real pinned Linux decoder entries verify file-output gains and tag precedence; physical acoustic/reference equivalence remains unmeasured. |
| P04 | Advanced pre-caching | Complete DirectPlay files can be prefetched into a separate profile cache, with a 0–2048 MiB quota, Wi-Fi policy, total request deadline, atomic promotion, hashed credential-qualified keys and LRU eviction. Current account visibility is rechecked before promotion/use; pinned downloads are separate. Transcodes and playlists retain streaming. | Quota/LRU, malformed/partial/oversized responses, network policy, authorization revocation and clear tests pass. |
| P05 | Streaming and conversion quality | Music streaming has general, remote and cellular settings, with cellular override precedence. Music downloads retain original representation; settings and offline policy explain that distinction. Output equivalence remains. | Precedence/persistence tests pass; no new format/device matrix. |
| P06 | Queue edits, shuffle and repeat | Full, Back To and Up Next views browse one authoritative queue. Jumps and filtered reorder/removal preserve occurrence positions; swipe removal retires the exact duplicate widget, and stale callbacks cannot edit replacement sessions. Continuation respects manual inserts, removals and clear-upcoming; shuffle restores canonical order. Touch/pointer holds stop the shared session from Now Playing, mini-player and driving transport; taps and keyboard SELECT retain play/pause. | Queue and playback tests pass; explicit filtered-view, duplicate removal, stale-session and 320px/200% text regressions pass. |
| P07 | Persistent large queues | Full queue, order, cursor and continuation metadata persist without a 1,000-track truncation. Listening history retains the loaded window through live database invalidation and uses keyset pages preserving repeated plays and timestamp ties. Queue edits now stage changed playback positions and upsert only changed metadata in bounded transactions; mode-only changes write no queue rows and tail appends write only new occurrences. The live queue still resides in RAM. | 10,000-track persistence, duplicate occurrences, cursor paging, tied timestamps, refresh/load races and migration regressions pass. |
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
| D01 | Station/radio families | Saved dynamic stations offer editable shuffle tracks, shuffle albums, least played and oldest releases presets. The editor fetches filters for the selected track or album target and guards reads against account changes. Album blocks with invalid children are skipped in full. Native catalog includes saved stations and server audio playlists. Reference radio algorithms and complete native station-family coverage remain. | Rule and native playlist loader tests pass; live provider comparison pending. |
| D02 | Autoplay continuation | Session-owned rolling tail retains dedupe, exclusions, EOF waiting and provenance. A refill rechecks the source account and authentication; persisted refills require an account scope, while older queues still restore parked. No independent offline recommendation generator. | Replacement, clear, manual insertion, EOF, pause, exhaustion, authentication rotation and scoped persistence tests pass. |
| D03 | Sonic similarity | Authorized Plex nearest requests added; exposed from integrated discovery. Independent non-Plex analysis and full reference tuning remain. | Plex request/authorization tests pass; live analyzed library pending. |
| D04 | Artist/album mix builders | Multi-seed editor, round-robin dedupe, preview, save/edit recipe, play-next, playlist and download added. Generation and subsequent preview actions recheck every source's account and visibility. Reference tuning controls and algorithm equivalence remain. | Recipe/generation, cross-source provenance and account-switch tests pass. |
| D05 | Personalized mixes | Music home now consumes bounded server-authored music recommendation families alongside device-local recent, rediscovery and period charts. Exact family identities/titles are preserved; provider failures remain distinct from empty results. Foreign libraries, backends and non-music rows are excluded. Account or visibility revocation invalidates completed previews and retained actions. Complete personalized/reference family equivalence remains. | Recommendation loader/widget, account/profile, shared album queue, budget/fairness and large-text regressions pass, alongside history/profile/layout tests. |
| D06 | Sonic Adventure | Ordered track waypoints, reorder controls and server computePath composition added. Shared endpoints are joined once; track-budget overflow fails instead of dropping destination. Full path constraints/equivalence remain. | Path and bounds tests pass; live server pending. |
| D07 | Guest DJ modes | Session-owned Stretch, Gemini, Freeze, Twofer, Groupie, Contempo and Friendgänger generation added. Friendgänger interleaves bounded pools from active visible shared libraries and rechecks every source after fetching. Exact reference tuning remains. | Mode, disabled/edited/replaced queue, shared-library revocation and account/session tests pass. |
| D08 | Sonic Sage / prompt playlists | Opt-in configurable HTTPS Chat Completions provider, protected credential storage, prompt-only disclosure, strict bounded response parser, authorized exact title/artist resolution, ambiguity selection, reorder/remove, playback and playlist saving added. | Consent, redirect/size rejection, ambiguity, source-revocation and large-text tests pass; live provider interoperability pending. |
| D09 | Aural Fixations / charts | Profile track/album/artist charts use qualified listening occurrences. Explicit paired import merges original occurrence IDs and cumulative maxima. A separate paged Plex server-history view reads track events for a visible music library under verified owner, managed or shared user credentials. Owner pages filter owner events; non-owner pages pin the personal server account returned under the user token. Provider events lack local occurrence IDs and duration, so they are not merged into local charts or scrobbled. Reference chart equivalence remains. | Occurrence/replay, account and library filtering, pagination, stale-source rejection, chart grouping and time-window tests pass. Live Plex history qualification remains. |
| D10 | Server analysis readiness | Track details check selected-stream loudness readiness and retain exact-track requests on supported PMS. Verified owners can also start or stop freshly advertised Sonic (MusicAnalysis) and loudness Butler tasks, with explicit confirmation that they apply to all eligible libraries on the server. The expanded foreground panel polls individual server activities, preserves indeterminate progress and distinguishes request acceptance from analysis readiness. It never invents a Sonic-only or per-library progress aggregate or changes scheduling preferences. | Guarded named-task API, account/route retirement, serialized writes, malformed/refused responses, confirmation and foreground polling tests pass. No live server job started; individual activity labels come from the server. |
| O01 | Music downloads | Preview tracks reuse existing profile-owned download flow; existing album/playlist downloads retained. Full offline representation qualification remains. | Existing implementation reused; new live download pending. |
| O02 | Mix/station/rule downloads | Finite stations have count/time/estimated-storage budgets, whole-album mode, refresh cadence and Wi-Fi policy. Account/rule-qualified failed batches retain their original candidates and estimates outside pruned completed snapshots. Offline playback intersects current owned downloads. | Scheduler, repeated retries, account/rule revocation, storage admission and owned-snapshot tests pass. Refresh does not silently delete existing downloads or promise a hard final-size cap. |
| O03 | Full offline music experience | Existing metadata/artwork downloads are enriched with authorized lyrics and bounded analysis. Native offline search and saved-station playback reuse completed owned files. Car cold-start source added; full representation/device qualification remains. | Offline bundle/snapshot and profile tests pass. Physical no-network startup unverified. |
| O04 | Offline play/rating reconciliation | Occurrence history and serialized rating/favorite writes coexist with progress reconciliation. Offline decisions retain their original base, surface server divergence, and require a revision-qualified local/remote choice. History imports from a negotiated paired peer match portable server/account/Home-user identity and preserve event IDs; unscoped legacy events are not exported and imports never scrobble. Cold-offline edits resolve a unique saved profile/account binding before any runtime client exists; replay requires the same live scope and compares the original remote base. Atomic server compare-and-set remains. | Journal conflict/revision, history pagination/replay/rollback, account/profile revocation and stale-acknowledgement tests pass. |
| O05 | Cache/download lifecycle | Profile teardown removes owned music documents and rejects late resurrection. Disposable precache has separate quotas/LRU; completed station snapshot metadata has bounded eviction, preserving pending retries and audio files. | Migration, teardown, snapshot migration/pruning, retry preservation and download ownership regressions pass. |
| U01 | Visualizers | Existing visualizer engine retained in normal UI; driving view intentionally avoids visualizers and exposes transport plus explicit Favorites/download shortcuts. Reference controls/visual inventory remains. | Visualizer rendering/motion and driving selection/ownership tests pass. |
| U02 | Artwork backgrounds/themes | Existing styling retained; full reference reactive-theme comparison remains. | Existing Now Playing tests pass. |
| U03 | Responsive layouts | Music tools extend ordinary app routes; home, prompt and audio forms were corrected for 320px/200% text. Full desktop/tablet/TV D-pad and native packaging matrix remains. | Large-text music tools/driving tests and retained music UI regressions pass. |
| U04 | Accessibility/localization | Music-tools strings, including NFC scanning actions, have explicit base-locale text and existing regional inheritance; widget transport labels use localized shared strings. Native fallback strings and human language/screen-reader review remain. | Localization/placeholder/source checks and 320px/200% text tests pass. |
| U05 | Shortcuts/widgets/settings | Android and provisioned iOS home-screen widgets use shared profile/queue-qualified transport. Android uses process-local metadata and requires internal installation. The iOS widget uses expiring display-only snapshots and interactive controls on iOS 17+; it never restores a queue from widget data. Desktop tray/shortcut reference comparison remains. | Shared transport, portable Swift snapshot and archive configuration regressions pass; signed iOS widget and physical device qualification remain pending. |
| U06 | Links/NFC | Durable server-qualified links resolve through profile authorization, including owned offline copies. Android and provisioned iPhones support foreground reads and writes with the same token-free NDEF link contract. Native writes check tag capacity and reader ownership; foreground scans reject profile changes and extra parameters. | Dart payload/cancellation/link-validation and signing-capability regressions pass. Signed iPhone builds and physical tag qualification remain pending. |
| R01 | Chromecast music | Shared Cast output keeps queue edits, repeats, shuffle, duplicate occurrences and OS controls in the music session. A separate bounded handoff transfers an online queue with repeat and continuation off to an idle receiver. It preserves playback order and occurrence, prepares paused, and confirms playback before pausing the sender. The receiver can advance that queue after sender disconnect. The sender can return at the current occurrence and playhead after a matching pause acknowledgement. Both modes check the receiver connection and media ownership; local DSP is bypassed. After restart, a bounded profile-owned record restores controls only when the receiver session, media session, queue token, occurrence and current account scopes all match. Recovery neither reloads playback nor persists stream URLs; records expire after seven days. | Output switching, takeover, authorization and timeout regressions pass. Detached queue tests cover duplicate occurrences, scoped source preparation, byte budgets, matching acknowledgement, safe return/rollback and both native bridge payloads. No live Cast or codec qualification. |
| R02 | AirPlay/system routes | Existing native routing is retained. Audio settings now inspect bounded reports from the audible renderer, including the independent native source speaker, and offer explicit recovery to the system default route/rate with exclusive mode off. Recovery preserves the queue, playhead, pause state and applied general DSP/cache policy. Remote outputs cannot be mistaken for a retained local decoder. On iOS/tvOS, the supported AVRoutePickerView selects the system audio-session route from the same panel; read-only AVAudioSession snapshots and route notifications show selected ports and rate. Observation retires in the background and newer events supersede delayed reads. macOS retains CoreAudio/mpv device selection, without claiming an AVPlayer picker routes mpv. | Physical-renderer ownership, read retirement, immutable reports, recovery and 320px/200% text tests pass; reported decoder/OS properties are not acoustic or DAC measurements. Native Apple route selection still requires the current platform build and physical route qualification; no new route hardware evidence. |
| R03 | Device control and handoff | One Play on picker connects paired nearby and remembered receivers. Receiver-authoritative controls and queue state use versioned bounded RPC, up to 4,096 occurrences, transactional prepare/freeze/commit, retry receipts, return-to-device and active-controller reconnect. Optional outbound E2E relay presence supports saved cross-network invitations. Existing version-1 transfer remains compatible. | The integrated suite passed 546 tests and both preflight checks at dedb73b, including encrypted loopback and WSS transports, interrupted commits and small-screen picker layouts. Verification is recorded in PLAY_ON_PLAN.md. Relay deployment, physical-device qualification and native-language review remain. |
| R04 | Headless Raspberry Pi | Linux ARM64 endpoint packaging, explicit headless launch mode and a managed user-service installer are present. Configure and authorize the profile normally first; virtual X11 dependencies remain. | Mode/profile and installer regressions pass; focused Linux x64 checks are not physical Pi or ARM64 package qualification. |
| R05 | Interoperability/grouping | Now Playing manages an existing control peer plus up to sixteen independently paired receivers. Each channel prepares paused, estimates monotonic clock offset/RTT, applies sequenced anchors and corrects drift above 250 ms. Per-endpoint departure leaves siblings and leader intact. Missing heartbeats, local edits and account/profile revocation retire ownership. Only the leader records progress/listens. Queue/mode replacement ends the group. A separate Caldera/Plexamp controller discovers native speakers, verifies the native state version and sends grouping, transport and volume commands. It controls existing native queues. Pleazyng can explicitly receive a selected native source over Xita through its shared music player, with the native Hello/membership exchange, monotonic clock mapping, bounded packet reordering, loss concealment and profile/account retirement. Explicit source transmission mixes bounded PCM from both fade decoders, preserving canonical 5.1/7.1 decoder layouts and folding other known surround/height layouts into stereo, and preserves the shared queue; peers acknowledge membership before capture output mutes. An independent clocked core renders the source speaker from the shared PCM without replacing the queue or repeating source DSP. Physical-output EQ, native per-speaker EQ and addressed-player user volume stay local; changing or muting the source preserves remote PCM and shared fade/headroom envelopes. A generated pinned-Linux native pulse reached the reported local audible clock within 8.7 ms of the UDP schedule in one null-output run. Serialized membership changes wait for retiring renderer, capture and Companion leases before rejoining. Workspace muting immediately silences buffered output, and Stop waits for renderer teardown. Selected peers receive source metadata and target-qualified, replay-protected transport controls. Receivers follow source metadata and forward shared transport to its verified Companion identity; paused membership drains silence and resumes without old PCM. The current dependency lock already contains ordered PCM exports. Opt-in native availability advertises and accepts incoming source/sink assignments using the same lease identity and shared session; bounded Hello, idempotent membership and immediate scope cancellation protect changes. Native full/additional-sink forms are accepted. Add/remove operations retain the source clock/UDP port, stage acknowledgement before PCM, preserve existing outputs on failed joins and retire peers independently. Local-source speaker edits retain shared-source ownership and Stop remains available after discovery loss. Stereo/5.1/7.1 wire output uses bounded saved-format negotiation and independent per-peer retirement; acoustic latency qualification remains. Audible MPV clock feedback now compensates reported renderer delay with bounded, continuous source/output resampling; unsupported/stalled clock reads retire the stream. | Independent multi-endpoint, legacy rejection, stale connection, clock skew, replay, heartbeat, duplicate cursor and account-revocation regressions pass. Native discovery, concatenated mesh parsing, real local HTTP/WebSocket control and 320px/200% native-controller UI regressions also pass. A Caldera 1.1.0 player in an isolated network namespace accepted the receive membership and supplied PCM to the Dart bridge; 121 focused receive/controller/shared-player tests pass. No acoustic/device qualification. |
| C01 | Apple CarPlay | CarPlay lists/Now Playing share the explicit phone/headless engine; pagination updates the current template. Siri media intents use the same catalog. Native browse artwork now uses opaque catalog references, bounded image bytes, authorized offline files, three concurrent requests and an account/route-fenced memory cache. Entitlement activation, native compilation and physical qualification remain. | Plist/Swift syntax parses; Dart catalog, real-image bridge and voice loaders pass. No new Xcode/device result claimed. |
| C02 | Android Auto | Native media browser/session retained; cold engine adds platform identity and vehicle restrictions. Warm phone engines can continue rebuilding profile state while attached to the car in background. | Dart bridge/bootstrap tests pass. New Kotlin compile and trusted-host/process-recreation qualification pending. |
| C03 | Android Automotive OS | Added a separate audio-category manifest selected by `pleazyngAutomotiveMedia`, host-rendered browsing/playback, parked setup, and media-only music allowance during restrictions. Normal distributions retain parked-only behavior. The native build attests target identity to Dart; the same profile/player/queue is reused. | Moving-vehicle music advancement and preserved video restriction tests pass. Native packaging, store acceptance and physical AAOS qualification remain. |
| C04 | Phone driving view | Manual entry and configurable foreground entry from projection or explicitly selected Bluetooth media outputs share the large-control view, Favorites and owned-download shortcuts. Saved Bluetooth identities are bounded and profile/platform-owned. Entry rechecks successful profile binding, foreground state and the master preference; stale inspections/events cannot open a retired profile. Only automatic routes close on disconnection or profile retirement. Bluetooth observation never starts audio, changes output or grants projection entitlement. Android uses the public media-attribute routing query on API 33+; older, unavailable or masked identities cannot arm entry. | 50 focused Flutter regressions pass, including 320px/200% text, stale selection/profile/PIN, manual-route preservation and projection behavior. Six Android route tests compile and pass against API 33 and pre-33 fixtures. Physical Bluetooth and vehicle qualification remain. |
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

### Server-analysis ReplayGain integration

Plex audio stream `gain` and `albumGain` are absolute dB values;
`peak` and `albumPeak` are linear sample amplitudes. Preserve these
through the source parser and downloaded metadata rather than estimating
absolute loudness from the relative seek-print envelope. Only the unambiguous
selected audio stream (or the sole stream when none is selected) supplies gain.
Malformed optional analysis cannot discard an otherwise playable stream.

Gain is bounded to -60 through +24 dB. Album mode falls back to track analysis
when album gain is absent. The analysis fallback is capped by the available
album/track peak; without a valid peak it can attenuate but cannot amplify.
Each replacement and appended native playlist entry carries its own mode,
clipping choice and fallback, including an explicit zero when disabled or
unavailable. This avoids applying the next track's gain to the outgoing audio.
Native ReplayGain tags retain precedence.

MPV applies `replaygain-fallback` even when its ReplayGain logic is inactive,
and skips the other ReplayGain controls for that fallback. Consequently Off
must explicitly clear it, and analysis needs its own peak bound. Regression
coverage includes source retirement during asynchronous application,
mode changes without redundant source resolution, shuffle/unshuffle, repeat,
offline and two-decoder handoff. A generated six-entry render using the pinned
Linux libmpv verified peaks near 0.1, 0.05, 0.2, 0.1, 0.05 and 0.2 for server
track, server album, missing analysis, native track precedence, native album
precedence and disabled leveling respectively. This measures decoder file
output; it does not qualify physical speakers.

Sources: [Plex client loudness field contract](https://pub.dev/documentation/dart_plex/latest/topics/Streaming-topic.html#loudness),
[MPV ReplayGain behavior](https://mpv.io/manual/stable/#options-replaygain-fallback),
[MPV file-local load options](https://mpv.io/manual/stable/#command-interface-loadfile).
