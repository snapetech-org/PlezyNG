# PlezyNG karaoke implementation

Owner request: implement the full 48-requirement karaoke assessment dated 2026-10-29.

## Execution constraints

- Dedicated branch; preserve main and existing work.
- Commit/push connected batches with `[skip ci]`. No tests, builds, analyzers or CI are run under the standing code-only instruction.
- Reuse existing music/source/player/subtitle ownership. Coordinate optional SeerrNG integration.
- Do not claim provider access, native packaging, singing-model accuracy or device qualification from source implementation.

## Requirement ledger

| ID | Phase | Requirement | Status |
|---|---|---|---|
| K01 | P0 | **Song, rendition and package identity.** Separate the composition/recording from its karaoke rendition and physical assets. Bind every lyric, stem, video and note chart to an edition, duration, digest and clock. Never infer karaoke readiness from an ordinary album being present. [PlezyNG design] | Partial: rendition/package source distinguishes ordinary server tracks as original-audio sing-along; rights and provider identity remain external |
| K02 | P0 | **One searchable karaoke library.** Index local, network, cloud and supported media-server sources through existing adapters. Add artist/title/language/genre/decade, duet, range, difficulty, explicit-content and ready/offline filters; preserve versions and producer/disc identifiers. [S01,S06,S13] | Partial: local packages and media-server tracks with genre/decade/difficulty/language/duet/scored/range/offline facets; no unified cloud/provider index or disc identifier |
| K03 | P1 | **Modern lyric formats.** Import/export line LRC, enhanced LRC, a documented TTML subset, WebVTT and lossless native packages. Preserve raw originals and provenance. Plain text remains explicitly untimed; expose unsupported semantics rather than silently dropping them. [C01-C04,S18] | Partial: LRC/VTT/TTML subset and package source; unsupported semantics remain limited |
| K04 | P1 | **Karaoke video and ASS/SSA.** Reuse existing video and native subtitle playback for karaoke video and authored ASS/SSA. Preserve karaoke tags, fonts and internal timing; do not silently flatten rich tracks. Add stage presentation and rendition-specific offsets. [C10,S06,S08] | Partial: local video/ASS playback and stage source; no full font/feature qualification |
| K05 | P1 | **CD+G collections.** Support paired MP3/WAV/OGG/FLAC plus CDG and bounded ZIP bundles. Add a CDG event decoder/renderer, seek checkpoints and shared-clock replay. Treat graphics timing independently from audio container discovery. [S06,S08] | Partial: paired package import and bounded CD+G renderer; no legacy-disc scanner |
| K06 | P1/P7 | **Open note charts and legacy assets.** Import UltraStar TXT with notes, duets, tempo, gaps and media references; add MIDI/KAR parsing plus an approved soundfont renderer. Schedule BIN/CDG-disc import on capable desktops. KMA/MCG/KFN require separate format/decoder feasibility work. [S06,S14] | Partial: UltraStar and MIDI/KAR source; no disc, KMA, MCG or KFN support |
| K07 | P1 | **Word and syllable timing.** Extend music lyrics without discarding span timing: start/end, ordered syllables, melismas, rests, section boundaries and source confidence. Adapt existing subtitle timing rather than creating a competing clock. Missing fine timing stays visibly line-level. [C01,C03,C09-C10] | Partial: timed spans, parts, translation and confidence fields; phonetic/ruby semantics remain limited |
| K08 | P1 | **Readable stage lyrics.** Show current/next lines, syllable sweeps, count-in, instrumental countdown and song progress. Support duet parts by labels as well as color, overlapping voices, transliteration/ruby and a separate translation lane. Keep the performance view uncluttered. [S01,S12-S14] | Partial: current/next, span sweep, count-in, part labels, translation and progress; no ruby lane |
| K09 | P1/P6 | **Multiple displays.** Separate host controls from a clean singer/audience display; include host preview. Support desktop secondary output and native TV stage mode first, then receiver-specific casting with explicit feature capability reporting. [S01,S06,S12] | Partial: in-app and browser stage surfaces; no native second-screen or casting integration |
| K10 | P2 | **Ready means the whole package.** Persist backing audio, optional stems, timed lyrics, note chart, video/fonts and rights metadata together. Validate completeness and checksums, support quotas and eviction, prefetch accepted requests and make an offline set auditable. [C08,S01,S04] | Partial: manifests, digests, quotas, eviction and offline audit; no prefetch/readiness certification |
| K11 | P0/P7 | **Provider connectors.** Add versioned catalog/auth/entitlement/playback/download capability interfaces. Prioritize KaraFun OEM evaluation; keep unavailable providers out of playable results. Retain original and licensed-cover identities and report plays only under a verified contract. [S17-S18] | Contract only: provider interface; no OEM credentials, adapter or content license |
| K12 | P2/P4 | **Favorites and discovery.** Add singer favorites, history, saved setlists, themed collections, recently added songs, preferred versions and request-missing-song actions. Rank vocal-fit suggestions using a singer-selected comfortable range, never a permanent voice-type label. [S01,S10,S13] | Partial: favorite/recent-played/recent-added filters, range-fit ranking, suggested keys and a host-reviewed missing-song inbox; no catalog fulfillment or themed recommendation service |
| K13 | P1 | **Key and tempo controls.** Expose independent transposition and speed in the karaoke player; reuse MPV effects when available and negotiate other backends explicitly. Persist singer/rendition preferences, provide reset and preview, and keep lyric/video/note timing aligned through seeks and rate changes. [C05,C07,S01,S16] | Partial: MPV controls and preferences; backend availability and device output remain unqualified |
| K14 | P3 | **A real vocal mixer.** Mix instrumental, lead, backing and duet-part stems on one sample clock, with separate levels/mutes and guide-vocal presets. Switch to the supplied instrumental when available; label generic center cancellation distinctly from separated vocals. [S01,S18] | Partial: local MPV stem graph, level/mute and presets; no independent buses or hardware qualification |
| K15 | P4 | **Prepare missing backing tracks.** Create bounded, cancellable separation jobs for accessible audio. Offer local or explicitly configured companion execution, model/version provenance, previews, retry/resume and cache invalidation. Preserve the source and label generated output until reviewed. [S14,S16,C10] | Partial: opt-in bounded companion jobs and review flow; model installs and accuracy are external |
| K16 | P3 | **Audio processing and routing.** Reuse EQ/normalization primitives and add karaoke buses, limiter, headroom, gain smoothing and feedback controls. Separate microphone, backing, monitor and recording outputs. Enter a decoded-PCM route when required and restore prior playback settings on exit. [C07,S08] | Partial: MPV effects, stem headroom and dry takes; no separate device buses or live mic monitor |
| K17 | P3 | **Local microphone support.** Generalize capture/device lifecycle code from Steam PR #81 into a music-capable input layer. Add channel-to-singer mapping, meters, permissions and unplug recovery. Qualify USB/interface inputs and provide external-mixer mode. Preserve Steam consent/ownership; voice-chat processing is not the karaoke default. [C13,S12-S13] | Partial: native PCM capture, permissions, meters and unplug timeout; no multichannel routing/qualification |
| K18 | P3 | **Phone microphone and pitch modes.** A phone can browse/request without mic access. Add separate capture modes for pitch-only scoring and timestamped voice transport; only the latter provides amplification/recording. Native companion support comes first; browser capture requires an eligible secure context. [S12,S15] | Partial: HTTPS phone pitch and optional private dry recording; no amplification or live monitoring |
| K19 | P3 | **Calibrated latency.** Measure and store per-device input, output and screen offsets; retain jitter/dropout telemetry and re-calibrate after route changes. Keep monitoring independent of display casting. Gate amplified monitoring by measured route quality; phone pitch-only mode is a separate capability. [PlezyNG design] | Partial: manual input/display offsets and bounded timestamp checks; no measured calibration or jitter qualification |
| K20 | P3/P5 | **Vocal effects.** Add per-mic reverb, echo, compressor and optional noise gating with dry/wet control. Preserve a dry recording. Offer pitch correction as an explicit effect, and distinguish assisted takes from raw scoring; do not score the corrected signal. [S09,S12] | Partial: post-production gate/echo/gain and dry take preservation; no real-time FX or pitch correction |
| K21 | P4 | **Practice and rehearsal.** Loop phrases, sections or A-B ranges, slow playback without changing key, add count-in/metronome, replay a singer take and compare it with the guide. Save practice markers and allow muted or isolated vocal parts. [S14,S16] | Partial: A-B loops, seek, skip and slow tempo; no metronome or guided comparison |
| K22 | P4 | **Range and musical guidance.** Offer opt-in comfortable-range calibration, suggested transpositions, live pitch trace and post-song pitch/rhythm summaries. Add key/BPM/chord analysis with confidence and correction tools. Use verified reference data for score-bearing guidance. [S01,S10,S16] | Partial: opt-in range estimate, pitch trace, score summary and marked analysis estimates; no correction UI |
| K23 | P2/P4 | **Useful skipping.** Add reversible skip-to-singing, intro/outro trim and long-instrumental skip markers. Preserve short musical pickups/count-ins; provide preview and host override. All skips update the source clock, chart, stems and record timeline atomically. [S05-S06] | Partial: reversible skip-to-singing and medley clips; no trim markers or preview workflow |
| K24 | P3/P4 | **Device-aware preparation.** Run costly separation/alignment before a performance where possible; prioritize audio deadlines. Cap memory/storage and allow cancellation. Qualify CPU/GPU providers per model/device instead of advertising universal GPU/NPU support. [C10; PlezyNG design] | Partial: bounded CPU companion jobs, cancellation and quota accounting; no scheduling/device qualification |
| K25 | P1 | **Integrated entry points.** Add Music > Karaoke, a Sing action on eligible tracks and a karaoke Now Playing mode. Use existing PlezyNG typography, tokens, navigation, focus and dark/light themes. Offer Sing, Host and Practice modes with progressive controls. [C04-C05; PlezyNG design] | Partial: Music/library launch, eligible track action, host and practice surfaces; no separate TV-first flow |
| K26 | P2 | **Persistent singer sessions.** Store participants, roles, selected songs, requested keys, duet partners and singer history. Keep ephemeral guests distinct from account profiles. Resume an interrupted party with the correct queue and paused performance, without unexpectedly enabling microphones. [S06-S08] | Partial: profile-local singers/queue and explicit paused recovery; no account-linked singer identity |
| K27 | P2 | **Fair rotation.** Support round-robin singer turns, per-singer song queues, new arrivals, absent singers, duets, limits and host overrides. Show the reason for ordering and an estimated turn time. Normal playlist order remains an alternate mode. [S06-S07] | Partial: round-robin rotation, absent singers, limits, reason and wait estimate; no alternate playlist mode |
| K28 | P2 | **QR guest songbook.** Serve a phone-friendly catalog and named requests without requiring PlezyNG installation. Let guests pick an allowed key/part, see their request state and cancel their own requests. Include optional voting, duplicate handling and explicit-content filters. [S04,S06; PlezyNG extensions] | Partial: QR room, key/part requests, own cancellation, host-enabled one-vote-per-singer up/down voting and host-controlled explicit-content filtering; no provider catalog |
| K29 | P2 | **Reliable host control.** Add approve/reject, reorder, hold, restart, next singer and end-session actions with acknowledgments, revisions and idempotent request IDs. A reconnect must not duplicate a song or claim a rejected request was accepted. [S04; PlezyNG design] | Partial: host UI now covers approval/rejection, manual queue order, pause/hold, restart, next and ending the active performance; no reconnect takeover protocol |
| K30 | P2 | **Room access and moderation.** Pair guests to one room with expiring scoped credentials; distinguish guest, singer, host and display rights. Bound request rates and uploads; allow removal and invitation revocation. Never disclose media-server tokens in guest links. [PlezyNG design] | Partial: expiring roles, one-use grants, rate limits and revocation; no external identity provider |
| K31 | P2/P3 | **Break music and announcements.** Automatically fade a separate background-music bus between performances. Add next-singer cards, waiting lists, configurable pause/countdown and manual or automatic starts. Announcements and break music must never leak into the recorded vocal stem. [S04,S06,S08] | Partial: rotating local instrumental filler and next-singer queue; no fades, announcements or separate bus |
| K32 | P5 | **Stage personalization.** Support custom logo/banner, still or video backgrounds, opt-in camera background, approved party photos and restrained reactions. Preserve lyric contrast and reduce-motion preferences. Save venue/presentation presets without changing global app appearance. [S01,S06,S12] | Partial: banner, contrast colors, text scale and offsets; no custom media backgrounds |
| K33 | P2/P5 | **Local and remote operation.** Keep local playback, queue and guest requests working on the LAN without a cloud account. Add optional relay-mediated remote rooms with versioned playback epochs. Remote participants get synchronized local tracks; do not assume zero-delay internet vocal mixing. [S06,S13; PlezyNG design] | Partial: LAN operation and versioned clock bridge; no hosted relay or remote rooms |
| K34 | P5/P7 | **Kiosk and venue operations.** Add a locked guest request surface, venue-scoped singers/history, show templates, emergency pause/mute and a clean host handover. Export printable PDF songbooks and CSV/XML catalogs. Include optional room schedules and reservation hooks. [S06,S17] | Partial: locked request route, venue controls and print-ready HTML/CSV/XML; no OS hardening, PDF or reservation hooks |
| K35 | P0/P2 | **SeerrNG coordination.** Share song/rendition/package IDs, readiness, guest requests and session commands with SeerrNG through a versioned contract. Choose exactly one queue authority per session; PlezyNG acknowledges real playback. Standalone karaoke must work without SeerrNG. [PlezyNG design] | Contract only: versioned bridge; SeerrNG adapter and deployed peer are unavailable |
| K36 | All | **Accessibility and localization.** Use durable localized keys and existing locale coverage; test RTL/bidi, CJK, mixed-script titles, long strings, high contrast, text scaling, screen readers and D-pad/gamepad/keyboard flows. Lyric timing must not split grapheme clusters. [C04; PlezyNG design] | Partial: English fallback and de/es/fr seeds plus accessible stage semantics; full locale and input audit unavailable |
| K37 | P4 | **Reference-based scoring.** Add real-time pitch, onset/duration and rhythm feedback from raw mic input against a reviewed note chart. Handle octave tolerance, silence, rap/free-pitch passages, harmonies, transposition and tempo. No chart means sing-along, not an invented accuracy score. [S02,S13] | Partial: reviewed chart scorer and opt-in estimates; phone and uncalibrated capture stay ineligible |
| K38 | P5 | **Fair multiplayer games.** Support optional solo scores, duets, teams, cooperative totals, battles, round-robin tournaments, medleys and leaderboards. Version the scoring rules and keep device calibration and assisted settings in results. Provide a no-score mode throughout. [S02,S13] | Partial: source for modes, team scores, medleys and verified tournament results; gameplay is not qualified |
| K39 | P5 | **Quizzes and party rounds.** Insert music trivia, lyric-completion and name-that-tune rounds into the session queue. Use licensed or user-authored questions and allowed clips; accept phone answers and resume singer rotation correctly after the interlude. [S03,S18] | Partial: host-authored questions and phone answers; pauses and resumes a live performance only when it was playing before the interlude; no licensed clip catalog |
| K40 | P4 | **Singing-specific alignment.** Extend the subtitle companion workflow to align approved lyrics against suitable vocal audio, preserve repeated choruses and sustained syllables, and surface uncertainty. Its current mix-pitch candidates are research evidence, not target notes. Require audition/review before scored publication. [C09-C10,S14] | Partial: forced text alignment and explicit review; model quality is not singing-qualified |
| K41 | P4 | **Integrated karaoke editor.** Add waveform and note lanes, syllable splits/merges, tap timing, duet assignment, section/medley markers and timing offsets. Reuse revision/undo services and export supported open formats without changing the original source. [C10,S14] | Partial: editor, note lane, prepared-waveform lane, timing, part/section cues and undo; no live waveform capture or dedicated syllable split/merge workflow |
| K42 | P5 | **Performance recording.** Record dry microphones, backing mix and optional camera to independent synchronized tracks. Handle storage limits, interruption recovery, latency compensation and take review. Save privately by default; never auto-publish a performance. [S08-S09] | Partial: bounded private dry mono takes and phone audio; no synchronized backing/camera recording |
| K43 | P5 | **Post-performance production.** Add vocal/backing balance, effect revision, trim, lyric overlay, video layouts and audio/video export. Preserve the dry take and editing recipe. Store rendition, clock, transposition and score-version provenance with each performance. [S09-S11,S16] | Partial: take mix, basic effects, lyric overlay and render export; no full layout editor |
| K44 | P5 | **Duet and group collaboration.** Create asynchronous invitations with fixed backing rendition/key/tempo, part assignments, isolated takes and explicit merge approval. Add private remote rooms and shared setlists first; stage monitoring and internet collaboration use different transport policies. [S09,S13] | Partial: fixed private invitations and reviewed take merge; no remote rehearsal rooms |
| K45 | P7 | **Optional community layer.** Plan opted-in profile libraries, performance links, shared song packages, following/comments/reactions, discovery and moderation. Public publishing requires an actual hosted service, access controls and supported content permissions; local recording stays independent. [S01,S09,S13] | Blocked: public community requires hosting, moderation and content permissions |
| K46 | P5 | **Portable collections and sync.** Export/import complete open packages, favorites, singer presets and setlists; optionally sync them through existing configured storage. Resolve conflicts explicitly and revoke sharing links. Data formats are versioned and preserve source identity. [S13,S16; PlezyNG design] | Partial: versioned singer/setlist collection and open package export; no account sync |
| K47 | P0/P6 | **Platform capability and packaging.** Publish per-build capabilities for formats, pitch/tempo, stems, microphones, scoring, capture and secondary output. Package codecs/DSP/models with version and license records. Unsupported features must return a specific reason rather than silently succeed. [C07,C10] | Partial: source capability gates and companion capability report; platform packaging remains unqualified |
| K48 | P6 | **Release evidence and completion.** Track implemented, integrated, packaged and device-qualified status separately for every requirement. Cover full menu-to-performance-to-save/next-singer flows, migration and failure recovery. Use private ephemeral JIT runners when validation is authorized; no hosted fallback. [C12] | Not qualified: no builds, tests, analyzers, CI or device checks run under the standing instruction |

## Delivery order

P0 contracts and package identity; P1 home karaoke; P2 party hosting; P3 audio/microphones; P4 preparation/practice/scoring; P5 games/recording/collaboration; P6 platform integration; P7 verified external providers and specialist formats.

## Audited foundations

- Main `e3450049cf477c74c535c27f3ecef3b7c8738607`.
- Subtitle PR #87: shared timings/rendering/revisions and experimental lyric alignment.
- Steam PR #81: platform microphone capture/permission/lifecycle, currently tied to voice-chat transport.
- Shared MPV effects already provide pitch, rate, EQ and normalization.
- Music lyric model and parser currently discard word/syllable detail.

## Sources

- https://www.karafun.com/features/
- https://business.karafun.com/en-ca/oem
- https://singa.com/business/singa-pro/
- https://www.powerkaraoke.com/src/prod_siglos-karaoke-professional.php
- https://github.com/OpenKJ/OpenKJ
- https://ultrastar-play.com/learn/song-editor
- https://ultrastar-play.com/learn/companion-app
- https://support.apple.com/en-ca/guide/tv/atvbd965bc0d/tvos
- https://moises.ai/products/moises-app/
- https://smule.zendesk.com/hc/en-us/articles/35739735608852-Pitch-Shifting-Backing-Track

## Implementation batch 1 — source integrated, not runtime qualified

- Added profile-scoped karaoke catalog/session persistence and a serialized command authority with durable receipts.
- Added Music/Library entry points, host queue, fair rotation, singer preferences, stage, practice loops, key/tempo and explicit resume.
- Preserved span timing in the shared lyric model and Plex/enhanced-LRC parsers. Added bounded LRC, WebVTT, TTML-subset and absolute UltraStar import plus LRC/VTT export.
- Added atomic package staging, path/size/digest checks, portable ZIP export, quota checks and explicit eviction protection.
- Added a source-clock CD+G decoder with palette/scroll/transparency checkpoints; local audio/video/ASS use existing player ownership.
- Current locale catalog has English fallback and partial German/Spanish/French translations; locale completion remains work in progress.
- No tests, builds, analyzers or CI executed. Runtime/platform behavior remains unverified.

## Implementation batch 2 — room and capture sources

- Embedded LAN songbook/stage with expiring scoped invitations, guest-owned requests, host handover, revision conflicts, bounded traffic and replay receipts. Media URLs/tokens are never serialized into the guest protocol.
- Native PCM capture through pinned `record` 7.1.2, music-oriented capture settings, explicit start, interruption/background retirement, bounded analysis/recording and private WAV takes with source-clock metadata.
- Reference-chart scoring, pitch trace and comfortable-range estimation. Seeking/settings invalidate competitive passes. No unreviewed chart is scored.
- Added OS permission descriptions and Linux package prerequisites. New dependency lock entries are pinned to published package metadata; dependency resolution and platform packaging have not run.
- At this checkpoint, remaining work included multichannel routing/monitoring, editor, preparation, production/collaboration, games, provider integration and locale completion; later checkpoints below record the source work completed since then.

## Implementation batch 3 — editing, mixing and preparation

- Connected the lyric/note editor, tap timing, part/translation fields, undo/redo, LRC/VTT export, chart review and shared subtitle revision history.
- Local stems use one MPV filter graph with explicit rendition clock identity, guide-vocal controls, headroom and a limiter.
- Added authenticated companion/client code for cancellable jobs, durable submission IDs, private credential storage, checksummed transfers, recoverable results and reviewed application.
- Companion workers implement waveform extraction, local Demucs separation, ordered forced alignment, isolated-vocal pitch proposals, estimated musical analysis, approved-soundfont MIDI rendering and take mix rendering.
- External codecs, model files and companion execution are prerequisites; none are installed, started or validated by this change.
- Existing no-tests/builds/analyzers/CI constraint remains in force.

### Implementation checkpoint 4 — 2026-10-29

Source added for PPQ MIDI/KAR chart import, private take recovery/review/production, fixed-rendition duet invitation/response validation, host-authored phone quizzes, private score records, tournament brackets and the versioned host integration endpoint. The provider contract negotiates capabilities and rechecks entitlement but no commercial provider adapter or contract is supplied. Remote-clock logic is a protocol component, not a deployed remote room. Teams/cooperative/battle/medley still need their gameplay integration.

Source review corrected unbounded MIDI reads, same-tick tempo ordering, quiz authorization before playback mutation, interrupted WAV preservation, no-score capture behavior, capture finalization after plugin failure, and local playback cancellation/cleanup. No tests, builds, analyzer or CI were run, per the standing instruction. Code presence is not hardware qualification.

### Implementation checkpoint 5 — 2026-10-29

Added group part assignment, venue controls, setlist queueing, collection import/export and catalog printing, offline package audit/eviction, local instrumental filler, host-authored tournament/medley controls, private phone input over trusted HTTPS, bounded PCM recording, lyric editor section cues, partner-take production, and a single-owner music queue snapshot/restore path. Companion uploads and completed jobs now have storage accounting and explicit deletion; stage analysis reads are coalesced. These remain source implementations: no relay, provider adapter, platform casting, multichannel monitor route, or device qualification is supplied. No tests, builds, analyzers or CI were run.

### Implementation checkpoint 6 — 2026-10-29

Completed a source-only integration pass for idempotent companion job deletion and retry URL handling, per-job output-space reservation and partial-job cleanup, local music queue restoration, coalesced stage-analysis reads, and duet owner/response provenance. Hosts can link a prior matching private take to an invitation; response mixes require the same invitation and rendition settings with complementary part metadata. No tests, builds, analyzers or CI were run.

### Implementation checkpoint 7 — 2026-10-29

Phone quiz interludes now remember whether a live performance was playing, pause it after validating the question, and resume it when the host ends the quiz. A manually paused performance stays paused; explicit host pause, resume, mode changes and session end cancel automatic resumption. Recovered sessions still require a deliberate host start. Source review only; no tests, builds, analyzers or CI were run.

### Implementation checkpoint 8 — 2026-10-29

Rendition metadata now persists optional genre, year and an explicit 1–5 difficulty value with backward-compatible defaults. UltraStar genre/year are indexed, invalid optional metadata is reported, and the library exposes genre, decade, difficulty, language, scored-chart, duet, offline and comfortable-range filters. Range fit and suggested key use the singer's opt-in range plus chart notes; ordinary untimed or unreviewed media is not presented as range-qualified. Songbook exports now include the added facets. The host room also exposes queue move-up/down, restart and end-performance controls; manual reorder switches to host playlist order. No tests, builds, analyzers or CI were run.

### Implementation checkpoint 9 — 2026-10-29

Added optional LAN queue voting. Hosts enable it in room settings; each paired singer can set one upvote, downvote or clear their vote on a waiting request. Vote identities are not exposed in room state, and the host and guests see only totals, net score and their own vote. Commands remain revisioned and idempotent. No tests, builds, analyzers or CI were run.

### Implementation checkpoint 10 — 2026-10-29

Ordinary media-server tracks remain available for lyric sing-along, but both the local and phone songbooks now identify them as original-audio sing-along without a reviewed score chart. They are not labeled as instrumental karaoke backing. No tests, builds, analyzers or CI were run.

### Implementation checkpoint 11 — 2026-10-29

Added singer-specific favorite and recently-played filters plus a recently-added sort based on catalog insertion order. The range-aware ranking and suggested-key behavior from checkpoint 8 remain opt-in and tied to saved singer range data. No tests, builds, analyzers or CI were run.

### Implementation checkpoint 12 — 2026-10-29

Added host-enabled queue voting for paired singers. Each vote is revisioned, replaces that singer's prior vote, and exposes only count, net score and the requesting singer's own selection. Disabling votes clears outstanding ballots. Ordinary media-server songs are explicitly labeled as original-audio sing-along in both songbooks. No tests, builds, analyzers or CI were run.

### Implementation checkpoint 13 — 2026-10-29

Added a bounded missing-song inbox for phone guests, deduplicated per singer/title/artist and capped at 256 open and 512 retained suggestions. Hosts can mark items sourced, reopen them or dismiss them in the native and phone host views. Guests see only their own suggestion status. This records demand but does not locate, license or import a song automatically. No tests, builds, analyzers or CI were run.

### Implementation checkpoint 14 — 2026-10-29

Connected prepared companion waveform peaks to the editor as a cached waveform lane with playback-position display and tap-to-seek for the active rendition. Phone-host inbox state now prioritizes open suggestions and includes resolved history; native hosts can reopen resolved items. Reopening enforces the open limit and prevents duplicate open entries. The phone catalog honors the host's explicit-content policy and labels allowed explicit tracks. No live waveform capture is added. Source review and whitespace checks only; no tests, builds, analyzers or CI were run.
