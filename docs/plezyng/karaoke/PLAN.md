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
| K01 | P0 | **Song, rendition and package identity.** Separate the composition/recording from its karaoke rendition and physical assets. Bind every lyric, stem, video and note chart to an edition, duration, digest and clock. Never infer karaoke readiness from an ordinary album being present. [PlezyNG design] | Pending |
| K02 | P0 | **One searchable karaoke library.** Index local, network, cloud and supported media-server sources through existing adapters. Add artist/title/language/genre/decade, duet, range, difficulty, explicit-content and ready/offline filters; preserve versions and producer/disc identifiers. [S01,S06,S13] | Pending |
| K03 | P1 | **Modern lyric formats.** Import/export line LRC, enhanced LRC, a documented TTML subset, WebVTT and lossless native packages. Preserve raw originals and provenance. Plain text remains explicitly untimed; expose unsupported semantics rather than silently dropping them. [C01-C04,S18] | Pending |
| K04 | P1 | **Karaoke video and ASS/SSA.** Reuse existing video and native subtitle playback for karaoke video and authored ASS/SSA. Preserve karaoke tags, fonts and internal timing; do not silently flatten rich tracks. Add stage presentation and rendition-specific offsets. [C10,S06,S08] | Pending |
| K05 | P1 | **CD+G collections.** Support paired MP3/WAV/OGG/FLAC plus CDG and bounded ZIP bundles. Add a CDG event decoder/renderer, seek checkpoints and shared-clock replay. Treat graphics timing independently from audio container discovery. [S06,S08] | Pending |
| K06 | P1/P7 | **Open note charts and legacy assets.** Import UltraStar TXT with notes, duets, tempo, gaps and media references; add MIDI/KAR parsing plus an approved soundfont renderer. Schedule BIN/CDG-disc import on capable desktops. KMA/MCG/KFN require separate format/decoder feasibility work. [S06,S14] | Pending |
| K07 | P1 | **Word and syllable timing.** Extend music lyrics without discarding span timing: start/end, ordered syllables, melismas, rests, section boundaries and source confidence. Adapt existing subtitle timing rather than creating a competing clock. Missing fine timing stays visibly line-level. [C01,C03,C09-C10] | Pending |
| K08 | P1 | **Readable stage lyrics.** Show current/next lines, syllable sweeps, count-in, instrumental countdown and song progress. Support duet parts by labels as well as color, overlapping voices, transliteration/ruby and a separate translation lane. Keep the performance view uncluttered. [S01,S12-S14] | Pending |
| K09 | P1/P6 | **Multiple displays.** Separate host controls from a clean singer/audience display; include host preview. Support desktop secondary output and native TV stage mode first, then receiver-specific casting with explicit feature capability reporting. [S01,S06,S12] | Pending |
| K10 | P2 | **Ready means the whole package.** Persist backing audio, optional stems, timed lyrics, note chart, video/fonts and rights metadata together. Validate completeness and checksums, support quotas and eviction, prefetch accepted requests and make an offline set auditable. [C08,S01,S04] | Pending |
| K11 | P0/P7 | **Provider connectors.** Add versioned catalog/auth/entitlement/playback/download capability interfaces. Prioritize KaraFun OEM evaluation; keep unavailable providers out of playable results. Retain original and licensed-cover identities and report plays only under a verified contract. [S17-S18] | Pending |
| K12 | P2/P4 | **Favorites and discovery.** Add singer favorites, history, saved setlists, themed collections, recently added songs, preferred versions and request-missing-song actions. Rank vocal-fit suggestions using a singer-selected comfortable range, never a permanent voice-type label. [S01,S10,S13] | Pending |
| K13 | P1 | **Key and tempo controls.** Expose independent transposition and speed in the karaoke player; reuse MPV effects when available and negotiate other backends explicitly. Persist singer/rendition preferences, provide reset and preview, and keep lyric/video/note timing aligned through seeks and rate changes. [C05,C07,S01,S16] | Pending |
| K14 | P3 | **A real vocal mixer.** Mix instrumental, lead, backing and duet-part stems on one sample clock, with separate levels/mutes and guide-vocal presets. Switch to the supplied instrumental when available; label generic center cancellation distinctly from separated vocals. [S01,S18] | Pending |
| K15 | P4 | **Prepare missing backing tracks.** Create bounded, cancellable separation jobs for accessible audio. Offer local or explicitly configured companion execution, model/version provenance, previews, retry/resume and cache invalidation. Preserve the source and label generated output until reviewed. [S14,S16,C10] | Pending |
| K16 | P3 | **Audio processing and routing.** Reuse EQ/normalization primitives and add karaoke buses, limiter, headroom, gain smoothing and feedback controls. Separate microphone, backing, monitor and recording outputs. Enter a decoded-PCM route when required and restore prior playback settings on exit. [C07,S08] | Pending |
| K17 | P3 | **Local microphone support.** Generalize capture/device lifecycle code from Steam PR #81 into a music-capable input layer. Add channel-to-singer mapping, meters, permissions and unplug recovery. Qualify USB/interface inputs and provide external-mixer mode. Preserve Steam consent/ownership; voice-chat processing is not the karaoke default. [C13,S12-S13] | Pending |
| K18 | P3 | **Phone microphone and pitch modes.** A phone can browse/request without mic access. Add separate capture modes for pitch-only scoring and timestamped voice transport; only the latter provides amplification/recording. Native companion support comes first; browser capture requires an eligible secure context. [S12,S15] | Pending |
| K19 | P3 | **Calibrated latency.** Measure and store per-device input, output and screen offsets; retain jitter/dropout telemetry and re-calibrate after route changes. Keep monitoring independent of display casting. Gate amplified monitoring by measured route quality; phone pitch-only mode is a separate capability. [PlezyNG design] | Pending |
| K20 | P3/P5 | **Vocal effects.** Add per-mic reverb, echo, compressor and optional noise gating with dry/wet control. Preserve a dry recording. Offer pitch correction as an explicit effect, and distinguish assisted takes from raw scoring; do not score the corrected signal. [S09,S12] | Pending |
| K21 | P4 | **Practice and rehearsal.** Loop phrases, sections or A-B ranges, slow playback without changing key, add count-in/metronome, replay a singer take and compare it with the guide. Save practice markers and allow muted or isolated vocal parts. [S14,S16] | Pending |
| K22 | P4 | **Range and musical guidance.** Offer opt-in comfortable-range calibration, suggested transpositions, live pitch trace and post-song pitch/rhythm summaries. Add key/BPM/chord analysis with confidence and correction tools. Use verified reference data for score-bearing guidance. [S01,S10,S16] | Pending |
| K23 | P2/P4 | **Useful skipping.** Add reversible skip-to-singing, intro/outro trim and long-instrumental skip markers. Preserve short musical pickups/count-ins; provide preview and host override. All skips update the source clock, chart, stems and record timeline atomically. [S05-S06] | Pending |
| K24 | P3/P4 | **Device-aware preparation.** Run costly separation/alignment before a performance where possible; prioritize audio deadlines. Cap memory/storage and allow cancellation. Qualify CPU/GPU providers per model/device instead of advertising universal GPU/NPU support. [C10; PlezyNG design] | Pending |
| K25 | P1 | **Integrated entry points.** Add Music > Karaoke, a Sing action on eligible tracks and a karaoke Now Playing mode. Use existing PlezyNG typography, tokens, navigation, focus and dark/light themes. Offer Sing, Host and Practice modes with progressive controls. [C04-C05; PlezyNG design] | Pending |
| K26 | P2 | **Persistent singer sessions.** Store participants, roles, selected songs, requested keys, duet partners and singer history. Keep ephemeral guests distinct from account profiles. Resume an interrupted party with the correct queue and paused performance, without unexpectedly enabling microphones. [S06-S08] | Pending |
| K27 | P2 | **Fair rotation.** Support round-robin singer turns, per-singer song queues, new arrivals, absent singers, duets, limits and host overrides. Show the reason for ordering and an estimated turn time. Normal playlist order remains an alternate mode. [S06-S07] | Pending |
| K28 | P2 | **QR guest songbook.** Serve a phone-friendly catalog and named requests without requiring PlezyNG installation. Let guests pick an allowed key/part, see their request state and cancel their own requests. Include optional voting, duplicate handling and explicit-content filters. [S04,S06; PlezyNG extensions] | Pending |
| K29 | P2 | **Reliable host control.** Add approve/reject, reorder, hold, restart, next singer and end-session actions with acknowledgments, revisions and idempotent request IDs. A reconnect must not duplicate a song or claim a rejected request was accepted. [S04; PlezyNG design] | Pending |
| K30 | P2 | **Room access and moderation.** Pair guests to one room with expiring scoped credentials; distinguish guest, singer, host and display rights. Bound request rates and uploads; allow removal and invitation revocation. Never disclose media-server tokens in guest links. [PlezyNG design] | Pending |
| K31 | P2/P3 | **Break music and announcements.** Automatically fade a separate background-music bus between performances. Add next-singer cards, waiting lists, configurable pause/countdown and manual or automatic starts. Announcements and break music must never leak into the recorded vocal stem. [S04,S06,S08] | Pending |
| K32 | P5 | **Stage personalization.** Support custom logo/banner, still or video backgrounds, opt-in camera background, approved party photos and restrained reactions. Preserve lyric contrast and reduce-motion preferences. Save venue/presentation presets without changing global app appearance. [S01,S06,S12] | Pending |
| K33 | P2/P5 | **Local and remote operation.** Keep local playback, queue and guest requests working on the LAN without a cloud account. Add optional relay-mediated remote rooms with versioned playback epochs. Remote participants get synchronized local tracks; do not assume zero-delay internet vocal mixing. [S06,S13; PlezyNG design] | Pending |
| K34 | P5/P7 | **Kiosk and venue operations.** Add a locked guest request surface, venue-scoped singers/history, show templates, emergency pause/mute and a clean host handover. Export printable PDF songbooks and CSV/XML catalogs. Include optional room schedules and reservation hooks. [S06,S17] | Pending |
| K35 | P0/P2 | **SeerrNG coordination.** Share song/rendition/package IDs, readiness, guest requests and session commands with SeerrNG through a versioned contract. Choose exactly one queue authority per session; PlezyNG acknowledges real playback. Standalone karaoke must work without SeerrNG. [PlezyNG design] | Pending |
| K36 | All | **Accessibility and localization.** Use durable localized keys and existing locale coverage; test RTL/bidi, CJK, mixed-script titles, long strings, high contrast, text scaling, screen readers and D-pad/gamepad/keyboard flows. Lyric timing must not split grapheme clusters. [C04; PlezyNG design] | Pending |
| K37 | P4 | **Reference-based scoring.** Add real-time pitch, onset/duration and rhythm feedback from raw mic input against a reviewed note chart. Handle octave tolerance, silence, rap/free-pitch passages, harmonies, transposition and tempo. No chart means sing-along, not an invented accuracy score. [S02,S13] | Pending |
| K38 | P5 | **Fair multiplayer games.** Support optional solo scores, duets, teams, cooperative totals, battles, round-robin tournaments, medleys and leaderboards. Version the scoring rules and keep device calibration and assisted settings in results. Provide a no-score mode throughout. [S02,S13] | Pending |
| K39 | P5 | **Quizzes and party rounds.** Insert music trivia, lyric-completion and name-that-tune rounds into the session queue. Use licensed or user-authored questions and allowed clips; accept phone answers and resume singer rotation correctly after the interlude. [S03,S18] | Pending |
| K40 | P4 | **Singing-specific alignment.** Extend the subtitle companion workflow to align approved lyrics against suitable vocal audio, preserve repeated choruses and sustained syllables, and surface uncertainty. Its current mix-pitch candidates are research evidence, not target notes. Require audition/review before scored publication. [C09-C10,S14] | Pending |
| K41 | P4 | **Integrated karaoke editor.** Add waveform and note lanes, syllable splits/merges, tap timing, duet assignment, section/medley markers and timing offsets. Reuse revision/undo services and export supported open formats without changing the original source. [C10,S14] | Pending |
| K42 | P5 | **Performance recording.** Record dry microphones, backing mix and optional camera to independent synchronized tracks. Handle storage limits, interruption recovery, latency compensation and take review. Save privately by default; never auto-publish a performance. [S08-S09] | Pending |
| K43 | P5 | **Post-performance production.** Add vocal/backing balance, effect revision, trim, lyric overlay, video layouts and audio/video export. Preserve the dry take and editing recipe. Store rendition, clock, transposition and score-version provenance with each performance. [S09-S11,S16] | Pending |
| K44 | P5 | **Duet and group collaboration.** Create asynchronous invitations with fixed backing rendition/key/tempo, part assignments, isolated takes and explicit merge approval. Add private remote rooms and shared setlists first; stage monitoring and internet collaboration use different transport policies. [S09,S13] | Pending |
| K45 | P7 | **Optional community layer.** Plan opted-in profile libraries, performance links, shared song packages, following/comments/reactions, discovery and moderation. Public publishing requires an actual hosted service, access controls and supported content permissions; local recording stays independent. [S01,S09,S13] | Pending |
| K46 | P5 | **Portable collections and sync.** Export/import complete open packages, favorites, singer presets and setlists; optionally sync them through existing configured storage. Resolve conflicts explicitly and revoke sharing links. Data formats are versioned and preserve source identity. [S13,S16; PlezyNG design] | Pending |
| K47 | P0/P6 | **Platform capability and packaging.** Publish per-build capabilities for formats, pitch/tempo, stems, microphones, scoring, capture and secondary output. Package codecs/DSP/models with version and license records. Unsupported features must return a specific reason rather than silently succeed. [C07,C10] | Pending |
| K48 | P6 | **Release evidence and completion.** Track implemented, integrated, packaged and device-qualified status separately for every requirement. Cover full menu-to-performance-to-save/next-singer flows, migration and failure recovery. Use private ephemeral JIT runners when validation is authorized; no hosted fallback. [C12] | Pending |

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
