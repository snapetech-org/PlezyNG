Warning: truncated output (original token count: 28760)
Total output lines: 689

# PlezyNG subtitle implementation plan

Prepared for Keith on October 28, 2026, UTC. The initial source audit is pinned to `snapetech-org/PlezyNG` main at `7c27c543aacd988258d6964c4b2046707a5b737c`; PR #53 opened against `8e24382c96deca0cd13e762e021ab80b95173fe8`. The implementation and requirements are updated against the live PR branch, which has merged main through `d6e5dad2dffa0c7fce351641972e62ffeb07fd83`. Source links preserve the initial audit context. Source presence is not device qualification; performance targets below are proposed acceptance gates, not measured results.

The catalogue contains **132 tracked requirements across ten work packages**, with existing-code mappings, competitor evidence, native-backend choices, and release gates. All requirements are in scope for this implementation effort; the work-package order records technical dependencies, not deferred approval phases. ASR means speech recognition; VAD means voice activity detection; SDH means subtitles for deaf and hard-of-hearing viewers; PTS means media presentation timestamps. RTF is processing time divided by audio duration, so lower is faster.

**Recommendation — confidence high:** extend PlezyNG's existing subtitle selection, rendering, download, and timing code. Add a shared subtitle session and document model, automatic synchronization, local transcription, translation, and optional companion processing. Preserve existing playback and UI ownership. Start with reliable timing and track identity, then CPU generation, opt-in desktop Vulkan/CUDA builds, local translation, and platform qualification.

**Feasibility — confidence high:** CPU subtitle generation and subtitle translation are practical; GPU/NPU acceleration is practical on supported device/runtime/model combinations. The integrated subtitle work includes local WAV-based ASR, Android ExoPlayer PCM capture, same- and cross-language subtitle sync/cut repair, word/token timings, device-local reviewed revisions, server upload, drop/share import, and cue replay paths. **Cross-platform player-owned PCM capture and per-operation accelerator placement remain unverified; device performance remains unknown until qualified on hardware.** **Demand ranking — confidence moderate:** the evidence shows recurring requests across projects, not a representative market survey. **Advanced audiovisual interpretation — confidence low:** usable prototypes are plausible, but accuracy cannot be promised.


## Integrated subtitle implementation status, October 28, 2026

- **CPU transcription:** whisper.cpp multilingual base Q5_1 transcribes a user-selected matching WAV on Android, iOS, desktop, and (after a Tizen package build) Tizen. Its model is downloaded and checksum-verified on demand. Whisper auto-detection is the default, with an optional per-profile language override for WAV and player PCM capture. On Android ExoPlayer VOD, users can opt into bounded capture of decoded 16-bit or float PCM. Tizen now has a native bounded 16 kHz mono PCM callback and its private package build compiles and verifies the matching CPU Whisper FFI bridge from the exact lockfile archive. Rolling five-second CPU Whisper windows provide delayed captions and a retained transcript for sync. Audio is not written to a recording file. The MPV fallback still needs rebuilt ordered-read libraries; Apple and webOS still need a WAV. Live inference results are discarded if the player session or selected audio track changes, and a start request is cancelled if playback changes while the model loads. The Tizen integration has not yet been built or TV-qualified; DRM and codec/device routes that reject PCM export remain unavailable.
- **GPU/NPU inference:** desktop Whisper backend selection follows native devices reported by the packaged runtime. A manually dispatched full build can opt into Vulkan for Windows/Linux x64 or CUDA for Windows x64, with pinned SDK bootstrap; release publishing remains on CPU. Sherpa ONNX requests Core ML, Qualcomm QNN, or Rockchip RKNN for the English Moonshine model and retries on CPU on failure. These are provider requests, not proof of per-layer placement; no target device has been qualified.
- **Translation:** spoken-audio-to-English is available through Whisper CPU/desktop-GPU mode. Existing SRT/VTT/ASS/SSA cue text uses on-device ML Kit on supported Android/iOS phones and tablets. Desktop subtitle-text translation is available through optional local Argos Translate Python and installed language-pair packages; a CUDA request is best effort and falls back to CPU. Timing and markup are preserved. ML Kit and Argos do not report per-operation placement. A bounded profile-scoped JSON glossary per language pair supports optional series overrides that inherit the profile entry; storage is capped at 32 series, 16 pairs per series, and 1 MiB per profile. Protected markup expansion is capped at 5 MiB. Translation review flags up to 100 cue-specific cases where a source glossary term appears without its intended target term. Generated, translated, and synchronized results show a bounded cue sample before attachment; viewers can edit any cue in a searchable full-track editor. Cross-language sync translates target cue text locally for matching, preserves the original text, and copies only aligned times back. Stable cue IDs, regional writing modes, and broader terminology QA remain open; edit-level undo is session-only while reviewed result revisions persist per server item on this device.
- **Automatic sync and cut repair:** a same-title WAV is transcribed and matched monotonically against same-language subtitle text. Android ExoPlayer users can instead sync against the captured watched portion. For cross-language subtitle references, the target cues are translated locally into the selected reference language for matching; the original target wording is retained while matched times are copied back. Global timing estimates offset/rate; cut repair uses piecewise offsets around matched anchors. Captured-playback cut repair preserves cue timing outside nearby speech evidence. A derived SRT is attached to the active backend when it advertises SRT attachment; source files remain untouched. Cross-language alignment depends on translation quality and reference suitability; the method is not edit-list detection or guaranteed release-cut identification.
- **Server library and import:** the subtitle sheet can upload bounded text subtitles to Plex, Jellyfin, or Emby where server permissions allow it. Android share intents and desktop drop events stage supported subtitle files and bounded ZIP and plain TAR archives; existing player-format capabilities decide which can attach.
- **Replay:** MPV can seek to the active text cue for primary or secondary subtitles, including embedded and server-provided tracks when the backend exposes cue timing. It leaves the active track and pause state alone. Other backends do not expose a universal cue-timing contract, so replay is capability-limited.

The player-owned PCM tap is available on Android ExoPlayer VOD. Linux MPV now has an ordered native drain bridge, but the locked libmpv runtime does not export the new symbol, so current shipped builds still require a matching WAV; the bridge becomes usable only with a rebuilt patched libmpv artifact. Tizen source now wires its native C player tap and builds the CPU Whisper FFI bridge into the Tizen package from the lockfile-verified source; this integration still needs a private-JIT package build and target-TV qualification. DRM and codecs/devices that reject PCM export remain unavailable. Other MPV and Apple players still need patched binaries or a WAV. webOS still requires a WAV because its native NDL player exposes no decoded PCM; browser playback remains unavailable because this app has no browser `Player`. Unsupported PCM layouts and tunneled/offloaded routes can produce no capture. System loopback is not treated as player audio because it can include unrelated applications. The app now labels provider initialization/fallback separately from execution evidence; Whisper and Sherpa do not expose per-operation GPU/NPU placement. Target-device subtitle qualification remains pending; the current environment does not expose the target GPU or player runtime.
# 1 What PlezyNG already has

The correct starting point is an established subtitle system. Rebuilding track selection or replacing libass would create avoidable regressions. The table distinguishes working code paths from settings, engine capabilities, and proposed additions.

| Existing area | Verified source and behavior | Extend or repair |
| --- | --- | --- |
| Shared player abstraction | `Player`, `PlayerBase`, `PlayerNative`, and platform implementations expose tracks, selection, properties, and events. [C01] | Introduce explicit subtitle capabilities and an analysis interface without another player owner. |
| Primary and secondary subtitles | `TrackSheet` selects primary and secondary tracks, provides numbered badges, and clears secondary when appropriate. `PlayerNative.selectSecondarySubtitleTrack` writes `secondary-sid`. [C02] [C03] | Make secondary selection discoverable, add independent timing/style, and qualify every renderer. This is an extension, not a new mpv feature. |
| Backend differences | ExoPlayer, Tizen, and webOS return `supportsSecondarySubtitles == false`; mpv inherits true and implements selection. [C04] | Add per-operation support results; do not promise all-platform dual subtitles from the existing Boolean. |
| Manual timing | `SyncOffsetControl` offers a ±10-second slider, 50 ms subtitle steps, 1-second held steps, and ±60-second absolute limits. Audio uses 10 ms steps. [C05] | PR #53 adds exact signed millisecond entry, MPV cue-step alignment, independent secondary delay, and bounded two-anchor linear-drift calibration for the active MPV text subtitle. The calibration applies a scoped timestamp multiplier and delay; image subtitles and unsupported players do not expose it. The drift dialog previews without saving and restores the prior delay/rate on cancel; one-step Undo restores the prior saved rate/delay until another timing edit or item change. Standalone MPV OpenSubtitles assets also persist calibrated delay/rate by profile, source edition, file fingerprint, subtitle digest, and selected audio descriptor; changing audio reapplies only its matching correction or neutral timing for an uncalibrated stream. One-cue alignment and corrected SRT/VTT plus safe ASS/SSA export are implemented for standalone MPV VOD. PR #53 adds local-WAV same-language ASR alignment and piecewise offset repair around text-match discontinuities. It reports matched cues and an estimated discontinuity count; it does not extract audio from playback, inspect container edit lists, or identify release cuts with a source fingerprint. |
| Timing persistence | `PlayerSyncOffsets` tracks what is actually applied; `ScopedPlayerPrefs` supports off/global/library/title scopes and resets on item changes. [C06] | Add edition/audio/subtitle-qualified correction records. The new subtitle timestamp multiplier uses the existing off/global/library/title scope; a title-level offset or rate is still insufficient for different cuts or downloaded subtitle releases. |
| Semantic preferences | `SubtitlePreference` separates item-local identity from cross-item `SubtitleIntent`; language and effective forced status are hard matching requirements. [C07] | A selected subtitle now carries explicit SDH/CC title-marker parity across library episode changes and saved show preferences, declining mismatched tracks so the server fallback remains available. This is title-based because the shared server/native contracts lack a dedicated hearing-impaired field. Ordered languages, regional script, origin, and generated-track intent remain open. Never carry raw native IDs across episodes. |
| Server and native reconciliation | `TrackManager`, `TrackSelectionService`, and `PlaybackSubtitleResolver` reconcile native tracks, source rows, sidecars, transcodes, and burned subtitles. [C07] [C08] | Keep these authorities. Add derived assets and explicit source/audio identities rather than bypassing them. |
| Selection races | Track management waits for late subtitle discovery, retires automatic selection after user action, and tracks session transitions. [C08] | Apply the same generation guards to analysis, translation, OCR, and downloads. |
| Server search | `SubtitleSearchSheet` calls backend search/download. Jellyfin/Emby adapters normalize language, hash-match, forced, hearing-impaired, and provider metadata; provider setup and server permissions still govern availability. [C09] | Unify result ranking and error states without making every server behave like Plex. |
| Automatic preferred-language download | `_fetchPreferredSubtitleIfNeeded` already searches when enabled, ranks perfect matches ahead of other results, downloads, rediscovers the source stream, and builds a sidecar. It skips offline/live, explicit preferences/off, and existing server selections. [C10] | Reuse it; improve confidence, provenance, nonblocking startup, and fallback to generation. Do not list automatic download as wholly missing. |
| Standalone source search | `OpenSubtitlesClient` and `StandaloneSubtitleSearchSheet` support API-key-backed direct search/download, including title IDs and SDH/forced result metadata. [C11] | PR #53 previews bounded SRT/VTT/ASS/SSA cue times and lines before applying a direct OpenSubtitles candidate. It persists applied OpenSubtitles text assets for MPV VOD in app-managed storage, bound to profile, source item, selected edition, and current file fingerprint; it records language/forced/SDH metadata, verifies SHA-256 on restore, and caps each file at 8 assets / 20 MiB. Delay/rate corrections are saved per selected audio descriptor and reapplied after audio-track changes. For exact local or cached files with a known matching byte size, search also sends the OpenSubtitles moviehash and ranks provider hash matches first. Release fingerprint matching and network-only source hashing remain open. |
| Source subtitle lifetime | `SourcePlayback.applyExternalSubtitle` attaches a bounded external track to MPV. [C12] | PR #53 keeps matching MPV VOD assets in an atomic, profile-scoped source-edition/file cache with manifest recovery and content verification. Delay/rate corrections are stored by subtitle digest and selected audio identity. This branch adds bounded SRT/VTT/ASS/SSA uploads to Plex, Jellyfin, and Emby library items; MediaBrowser uploads carry language/forced/SDH metadata and Plex receives the supported filename/format fields. The server's upload permissions decide whether a write is accepted. Generated, translated, and repaired derivatives are attached to the active session as SRT when the backend advertises SRT support. Writing generated server-side assets, standalone-source sidecars, custom subtitle roots, and cross-device sync remain open. The upload path is not test-verified or device-qualified. |
| Local subtitle import | The track sheet previously hid ExoPlayer despite an existing native `addSubtitleTrack` path; its shared `command` adapter did not route `sub-add`. Tizen/webOS command handlers were no-ops. [C02] | PR #53 adds a format capability contract and routes local SRT/ASS/SSA/VTT to ExoPlayer VOD, bounded SRT/VTT overlays to Tizen/webOS, and keeps mpv’s existing formats. ZIP preflight checks central-directory bounds and caps inputs at 50 MiB compressed / 64 MiB expanded / 32 MiB per member. Plain TAR preflight verifies header checksums and end markers, rejects links, special files, PAX/GNU extensions and unsafe paths, and applies 50 MiB input / 64 MiB expanded / 32 MiB per-member limits. Both formats materialize only backend-supported entries; paired IDX/SUB imports require both files. Bounded Android share-intent files and desktop drop files/ZIPs/TARs enter the same import candidate flow. Live ExoPlayer attachment and direct paired IDX/SUB validation remain open. Android and TV device behavior is not qualified. |
| In-player appearance | `InPlayerSubtitleStyleSheet` exposes font size and vertical position. [C13] | This PR now exposes text color, bold/italic, outline size/color, and background opacity/color in-player for MPV and ExoPlayer, while unsupported TV backends hide the style action. Independent primary/secondary targeting and presets remain. The sheet now includes a one-tap reset to stored defaults. |
| Full appearance settings | `SubtitleStylingScreen` already provides ASS override choices, render-resolution choices, font size/color, position, margins/anchoring, bold/italic, outline, and background with preview. [C14] | Reuse existing settings and preview. Add legibility controls and apply/error acknowledgement. |
| ASS and bitmap rendering | mpv/libass and Android's libass atlas/rendering code provide substantial native rendering infrastructure. Android also has PGS parsing and subtitle geometry tests. [C15] | Preserve ASS drawing, overlap, fonts, positioning, and karaoke. Derived plain-text views must not silently destroy the original track. |
| Android subtitle delay | ExoPlayer forwards `sub-delay` into `setSubtitleDelay`; native text and ASS rendering account for that offset. `AssLatencyCalibrator` concerns overlay/video presentation latency. [C15] | Keep presentation calibration separate from dialogue-to-cue alignment. The calibrator is not automatic subtitle synchronization. |
| Tizen and webOS | Tizen implements SRT/VTT sidecars with bounded reads and a timed caption path; webOS selects native indexed subtitle tracks and forwards subtitle sync. Both lack secondary selection. [C04] | Qualify bitmap/styled/native tracks separately; implement shared generated-text overlays only where surfaces, clocks, PiP, and exports permit. |
| Downloads | Supplementary subtitle downloads are already resolved and stored per media part, with retry and cleanup integration. [C16] | Include original/translated/generated assets, fonts, revision manifests, and incomplete-job recovery. |
| Visibility and burned text | Existing controls distinguish hiding an overlay from changing a subtitle burned into a server rendition. [C17] | Keep this distinction in all new actions. Hide cannot remove pixels from an already encoded video. |
| GPU and native foundations | Native video output, hardware decoding, libass compositing, and DV work are present. The reviewed source does not establish a general speech-inference runtime, model registry, PCM analysis API, or production NPU subsystem. [C01] [C15] [C18] | PR #53 adds whisper.cpp package integration for multilingual CPU and optional compiled desktop CUDA/Vulkan, plus Sherpa ONNX Moonshine provider requests for Core ML/QNN/RKNN. The API can report the selected/requested backend and CPU fallback, not per-operation placement. Video decode acceleration still does not imply ASR acceleration; device builds and NPU support need qualification. |

Two baseline corrections matter. First, the `Player` factory and `SettingsService.useExoPlayer` select **mpv by default on Android**, with ExoPlayer opt-in; a README footnote still says otherwise. Second, source-path subtitle search and media-server playback are separate flows today. The new subsystem must serve both, without assuming a `MediaItem` exists for every source. [C01] [C12] [C19]

Open PR #40 at `5e1985066d1aecaeb6a4fa240f5203a846d8cae5` adds motion controls and an FFmpeg `minterpolate` adapter. It is not a shipping general neural/NPU inference layer. Open PR #43 at `cabeb731919b11da1a76bf6119feb4e9af96295d` changes shared player/source controls, bookmarks, and looping. Reconcile both before editing overlapping files; neither is part of this main snapshot. [C20] [C21]

## Platform baseline

| Playback path | Existing subtitle path | First AI implementation | Main qualification gap |
| --- | --- | --- | --- |
| Linux and Windows mpv | Native track selection, secondary track, libass, property-based timing/style | Native CPU worker plus Vulkan; optional HIP/CUDA builds | PCM access, display-plane integration, resource contention, sandbox packaging |
| macOS and iOS/tvOS mpv integration | MPVKit/libmpv with Apple-specific video output; subtitle plumbing remains native | CPU/Metal first; Core ML/ANE adapter independently benchmarked | PiP, AVFoundation composition, memory/thermal/background limits; no assumption that mpv GPU filters are available |
| Android mpv | Primary/secondary mpv path | CPU; Vulkan where qualified; optional vendor NPU later | Decoder/passthrough coexistence, process lifetime, device/driver variability |
| Android ExoPlayer | Native text plus custom ASS rendering; primary only; PR #53 routes local SRT/ASS/SSA/VTT import through the existing Media3 re-prepare path, preserving the current position on VOD | Analysis decoder or approved PCM tap; generated-text renderer | Live external attachment, dual renderers, clock mapping, hardware offload; no Android device qualification in this PR |
| Tizen | Native video, remote sidecars, and local SRT/VTT overlay import (PR #53; not device-qualified) | Companion-generated or precomputed captions first | Hardware/firmware timing, PiP, and limited CPU/storage/API access |
| webOS | Native indexed track selection/sync plus local SRT/VTT text overlay import (PR #53; not device-qualified) | Companion/precomputed output for generation | Overlay timing/placement, PiP, and supported devices/firmware |
| Cast/external player | Receiver owns rendering and often fetches media independently | Export/serve compatible sidecar or explicit burn-in/transcode | Local Flutter overlays do not travel to the receiver |

# 2 What competitors do well and where the opportunity remains

These are documented capabilities and bounded gaps, not claims that every version or device behaves identically.

| Client or tool | What to borrow | Limitation or lesson for PlezyNG |
| --- | --- | --- |
| Plex | Automatic speech-activity-based synchronization; familiar language defaults and subtitle search. | Documented auto-sync requires analysis and Plex Pass entitlements, handles external SRT, analyzes the primary audio track, and has limitations around large offsets and inconsistent cuts. PlezyNG can support the actual selected audio and non-Plex sources. [W01] |
| Infuse | Low-friction subtitle downloads and broad format coverage in an integrated media-library player. | Repeated dual-subtitle and automatic-sync requests identify opportunities. Request threads establish demand; they do not prove every current Infuse build lacks every proposed feature. [W02] [W03] [W04] |
| mpv | Dual tracks, timing offsets, timestamp scaling, cue navigation, ASS support, and scriptable commands. | Secondary rendering has styling and bitmap-position caveats. Engine capability needs a discoverable UI and reliable persistence. PlezyNG already uses this foundation. [W05] |
| IINA | A native interface around mpv, provider plugins, online subtitle search, and clickable-subtitle extensions. | Plugin features are not the same as built-in cross-platform behavior. Borrow provider interfaces and word lookup without depending on user-installed scripts. [W06] |
| Kodi | Forced/language/hearing-impaired preferences, custom subtitle directories, extensive style controls, HDR UI-luminance control. | Text styling cannot restyle bitmap glyphs. Preference breadth needs understandable controls. Keep Keith's separate subtitle directory possible. [W07] |
| VLC | Delay shortcuts and a bookmark-audio/bookmark-subtitle/apply workflow that is more usable than guessing offsets. | A demonstrated or early-access AI feature is not a universally delivered desktop/mobile feature. Videolabs' current AI plugin page explicitly says it is not generally available. [W08] [W09] |
| Jellyfin clients | Server metadata and provider integration; web and native clients serve different use cases. | Dual-subtitle demand persists in Desktop; historical Android TV offset requests show the cost of uneven client support. Avoid treating the entire ecosystem as one feature set. [W10] [W11] |
| Emby | Server-driven manual and automatic subtitle downloads with provider plugins and matching controls. | Downloads depend on server configuration and permissions; discovery does not itself solve timing, wrong editions, or generation. [W12] |
| MPC-HC | Efficient native rendering, optional libass, WebVTT, manual/automatic subtitle search, and configurable player controls. | Its Windows desktop model is not a portable mobile/TV implementation. Useful quality and power-user reference. [W13] |
| Subtitle Edit | Rich editing, waveform timing, OCR, translation, speech recognition, format conversion, and batch work. | It is an authoring workflow. PlezyNG's opportunity is to make selected capabilities work safely during playback, then offer advanced editing on demand. [W14] |
| Bazarr | Automated provider search, audio synchronization, Whisper fallback, and translation integrations. | Useful companion integration for libraries. It does not eliminate the need for player-clock-aware live generation, transient streams, or per-viewer preferences. [W15] |
| Language-learning extensions | Dual text, word lookup, cue replay, saved vocabulary, and automatic pause at cue boundaries. | These interaction patterns can be integrated with local files, offline viewing, and remote controls. [W16] |
| Windows/Chrome live captions | Captions for otherwise uncaptioned audio; supported translation modes. | OS/browser captions are not automatically edition-bound, exportable subtitle assets controlled by the media client. Supported language/output combinations differ. [W17] [W18] |

## Recurring demand ranked for implementation

| Priority | Demand evidence | PlezyNG response |
| --- | --- | --- |
| 1 | Infuse automatic-sync requests span years; Plex shipped a constrained implementation. | One-action sync with preview, confidence, undo, selected-audio analysis, and drift/cut support. |
| 2 | Infuse multiple-subtitle threads recur over years. Jellyfin Desktop #1223 revisits an earlier issue described as having 47 thumbs-up; the current issue remains open at retrieval. | Finish dual-track UX and timing on mpv; extend capable non-mpv paths instead of claiming universal support. |
| 3 | Jellyfin Android TV #1234 accumulated 32 thumbs-up and 4 hearts; it is closed, so use it as historical demand, not proof of a current missing feature. | Explicit per-backend capability matrix and the same understandable timing controls wherever implemented. |
| 4 | Upstream Plezy #689 requests styling without leaving playback and has 7 thumbs-up. PlezyNG already implements size/position. | Complete the existing in-player style sheet; do not rebuild it. [C22] |
| 5 | Subtitle Edit, Bazarr, and emerging VLC integrations show active delivery around ASR, OCR, and translation. | Integrate these in a playback-oriented workflow. Demand for an exact PlezyNG implementation is unquantified. |
| 6 | Styling/position/overlap reports demonstrate edge cases that survive nominal format support. | Treat ASS fidelity, bitmap geometry, accessibility, HDR brightness, and overlap as first-class acceptance work. [W19] |

The most defensible differentiation is **reliable subtitle behavior across sources and devices**, with automatic repair and local generation behind the existing subtitle controls. The largest recurring gaps are integration, identity, timing, and delivery consistency; an additional model alone does not solve them.

# 3 User experience and selection policy

Keep the existing Tracks/Subtitles sheet. Its main rows are Off, Primary, and optional Secondary. Below them, group **Find or add**, **Timing**, **Appearance**, and **Translate or generate**. Advanced controls expand inside those surfaces. Put transcript/search/learning tools behind a secondary action. Do not add a top-level subtitle section to the main navigation.

During playback, **Fix timing** offers automatic analysis, a short before/after preview, Apply, and Undo. **Translate** offers the source track and target language, then attaches a separate derivative. **Generate** offers audio language, quality, and whether to process this device or a configured companion. Runtime/model details belong in advanced status; the ordinary flow should say Ready, Preparing, Generating, or Unable to keep up, with a concrete next action.

Proposed selection order: explicit current-session choice or Off; valid saved choice for this edition; configured semantic preference; authoritative server selection; optional preferred-language provider search; optional translation of a suitable existing track; optional ASR generation. Respect the existing server/default ladder during migration: implement this as a reconciled policy with regression fixtures, not a wholesale reorder. Explicit Off suppresses automatic fallback. Missing subtitles must not unexpectedly start model downloads or cloud processing.

Separate preference axes: spoken-audio language, preferred subtitle languages, regional script, forced versus full dialogue, SDH/CC preference, primary versus secondary, and origin preference. A subtitle language can differ from the audio. A translation of original dialogue can differ substantially from a localized dub; offer **Match selected audio** when that matters.

# 4 Shared architecture

Use a shared `SubtitleSession` for both `VideoPlayerScreen` and `SourcePlayback`. It coordinates existing owners rather than replacing the player. Heavy work lives in native workers or an optional companion. Flutter owns controls, progress, selection, and document editing.

```mermaid
flowchart TD
  A["Tracks and sidecars"] --> D["Subtitle asset store"]
  B["Selected audio and media clock"] --> C["Analysis worker"]
  C -->|"Speech and timing evidence"| E["Subtitle session"]
  D --> E
  E --> F["Sync and translation jobs"]
  F --> D
  E --> G["Native or shared renderer"]
  H["Capability and resource broker"] --> C
  H --> F
  G --> I["Player controls and transcript"]
```

## Domain contracts

| Proposed contract | Required content and invariants |
| --- | --- |
| `SubtitleAssetKey` | Profile, source identity, media representation/edition, part, subtitle content digest, selected analysis-audio identity where relevant. Signed URLs and native track ordinals are not durable identity. |
| `SubtitleDocument` | Original bytes/reference; parsed cue graph; language/script; format; track roles; metadata; attachments; immutable revision; generated/translated/OCR provenance. Keep authored material intact. |
| `SubtitleCue` | Stable ID, source start/end in integer microseconds, text spans or bitmap references, region/layer, optional word spans, speaker label, confidence/uncertainty, and source-cue correspondence. Overlapping cues are valid. |
| `TimelineTransform` | Offset, affine mapping, piecewise mapping, unmapped ranges, user anchors, confidence evidence, and transform revision. Editing text and editing timing are independent operations. |
| `SubtitleSession` | Current source/audio/edition/part, primary/secondary asset and revision, playback epoch, selected policy, applied transforms, in-flight jobs, renderer acknowledgement. |
| `SubtitleCapabilities` | Select/import/dual/style/delay/affine/cue-stream/bitmap/ASS/PCM/read-ahead/PiP/cast/export capabilities, per format and renderer, with supported/unsupported/unknown plus reason. |
| `MediaAnalysisSource` | Selected audio access, decoder configuration, PTS and discontinuities, seek/range access, authenticated renewable transport, and a permitted extraction mode. Never assume a public file URL. |
| `AsrBackend` | Model/language/task support, actual execution device, precision, startup and streaming modes, cancellation, bounded audio submission, partial/final outputs, measured resource use. |
| `TranslationBackend` | Explicit language pairs, context limits, glossary support, origin, model revision, structured cue correspondence, cancellation, and optional remote execution. |
| `AnalysisJobStore` | Durable state, input digests, checkpoint ranges, dependencies, priority, retry/backoff, cancellation, revision guards, and atomic result commit. |
| `InferenceResourceBroker` | Real device capabilities and measured budgets shared with video decode, shaders, DV, motion interpolation, multiview, games, and other inference. |

Every asynchronous output includes `profileId`, `sourceRevision`, `audioTrackKey`, `playbackEpoch`, `jobId`, and sequence/revision. A seek retires obsolete live work; an audio switch starts a distinct transcript; changing profiles cancels and isolates jobs. Stale results may remain as valid cached assets for their original input, but may never select or display themselves in the current session.

## Audio extraction and playback clocks

Prefer a native pre-output audio tap with original media timestamps. Use a dedicated bounded analysis decoder for VOD read-ahead and when passthrough/offload does not expose PCM. Preserve the audible output mode; do not silently decode an Atmos/DTS bitstream into a different playback output merely to obtain speech samples. A second analysis stream may consume bandwidth or fail on a one-shot/live/protected source; capability detection must state that.

Keep original channel layout for optional speaker/separation analysis. Produce the ASR model's required input separately, commonly 16 kHz mono for Whisper, with known resampler delay. Never feed time-stretched playback audio as if it were source-time audio. Center-channel weighting is optional and falls back to the full mix; dialogue is not guaranteed to occupy the center channel.

Use integer source PTS and explicit mappings for source start offsets, multipart media, transcode seek bases, HLS discontinuities, DVR windows, and playback speed. UI timers and wall-clock timestamps are not the authority. Keep manual audio delay, subtitle correction, and measured output-plane latency as separate terms and apply each exactly once. Test sign conventions with a tone/word/cue fixture.

Native rings should be bounded and nonblocking. A 60-second 16 kHz float32 mono ring is 3.84 MB before metadata; original multichannel buffers are larger. Pass buffers through FFI/shared native ownership, not repeated large platform-channel JSON messages. Throttle events and handle cancellation outside the audio callback.

## Rendering and storage

Render original authored ASS with the existing native path. For secondary subtitles, preserve documented mpv limitations until a tested renderer enhancement exists. Build an independent text/cue representation for search, translation, learning, and editing; it is not a replacement for the original ASS script. Use a dedicated generated-text track or bounded native cue stream for live output. Do not repeatedly reload an ever-growing SRT and hope track selection, timing, and memory remain correct.

Persist derived assets under a profile-scoped managed store, with an optional configurable external subtitle root. Support Keith's `/mnt/datapool/subs` arrangement without moving existing files beside videos. Keep media fingerprints and a manifest that maps files to subtitle assets. Export beside media only when that destination is explicitly chosen. Downloads and source transports retain their current authority over files and credentials.

Cache keys include audio identity, source representation, model checksum, task/language, precision where output differs, decoder settings, glossary revision, and transformation version. Reuse a source transcript across translations; do not retranscribe each target language. A changed dub or cut must invalidate the corresponding timeline/ASR binding. Reuse across server URLs only after content identity is established.

# 5 Synchronization from simple correction to difficult edits

**Confidence high:** ordinary synchronization should start with lightweight analysis. Speech recognition is an optional escalation, not a prerequisite. `ffsubsync` aligns speech/subtitle activity, while `alass` provides a useful reference for split-aware alignment. WhisperX demonstrates word alignment, but overlapping speech and unsupported alignment vocabularies remain limitations. [W20] [W21] [W22]

| Timing problem | Proposed method | Refusal or escalation condition |
| --- | --- | --- |
| Constant delay | Manual offset; one anchor; VAD/subtitle-activity correlation | Sparse dialogue, repeated patterns, weak correlation, wrong audio |
| Uniform drift | Two anchors or robust affine fit across several windows | Residuals vary by scene; a single stretch damages good sections |
| Frame-rate conversion | Explicit timestamp ratio with anchor preview | VFR alone does not imply a subtitle-speed correction; never infer only from nominal FPS |
| Added logos or trimmed opening | Offset after finding matching dialogue | Nonmatching early content must remain unmapped |
| Ads, recap removal, different cuts | Piecewise monotonic alignment with insertion/deletion handling | Missing scenes cannot be repaired by stretching unrelated lines |
| Accurate words but bad cue boundaries | Forced alignment on the same spoken language and matching transcript | Translation, paraphrase, dub differences, music, or overlapping speakers invalidate literal alignment |
| Translation with different segmentation | Match broader speech activity or an already aligned source subtitle | Do not force-align translated words to unrelated phonemes |
| Live/DVR timestamp jumps | Segment-aware PTS mapping and epoch resets | A discontinuity is not a gradual drift to smooth over |
| Audio device/render latency | Existing audio delay and presentation calibration | Never bake a Bluetooth/output-specific delay into a portable subtitle asset |

Canonical timestamp mapping is `t_media = a × t_subtitle + b`. One anchor determines `b` with `a = 1`; two distinct anchors determine `a` and `b`. For example, if subtitle time 60 seconds belongs at media time 62 seconds and subtitle time 660 belongs at 662.6, then `a = 1.001` and `b = 1.94`. Transform both cue boundaries. Positive `b` delays display. Test actual mpv option composition before mapping this directly to `sub-speed` and `sub-delay`; exporting transformed timestamps is the portable reference implementation.

Automatic procedure: validate track and audio identities; obtain bounded speech activity windows; remove obvious nonspeech subtitle events from the alignment signal without deleting them from the asset; fit global offset; inspect residuals across independent windows; try affine mapping; escalate to piecewise matching; optionally use ASR/forced alignment for ambiguous same-language sections. Evaluate a held-out window before proposing a correction. Do not treat a correlation coefficient as a calibrated probability.

Use robust estimation, monotonic constraints, minimum anchor spacing, rate-change limits, and explicit unmapped spans. Permit discontinuous jumps for edited cuts, but prevent time reversal. Avoid forcing continuity across content that was removed. Keep a correction undo stack, user anchors, and a reset-to-original action. A low-confidence result must leave playback unchanged and offer manual anchoring or another subtitle release.

For ASS, shifting event boundaries is straightforward; changing event duration can also affect karaoke syllables, animated transforms, fades, and movement timing. An affine or piecewise repair must transform relevant internal timing consistently, or mark that track as unsupported for full-fidelity retiming. For bitmap tracks, shift presentation events; font and wording changes require OCR or another source. Never convert a complex ASS script to SRT as a silent repair.

# 6 Subtitle generation during and before playback

**Yes: generate on the CPU, GPU, or a supported NPU.** The useful distinction is whether analysis has access to fut…8760 tokens truncated…ce remains readable in SDR/HDR without searing white; qualify actual output paths. | M6 |
| R10 | Avoid collisions between tracks, player chrome, and authored signs without continuously jumping text. | M6 |
| R11 | Dynamic face/object-aware placement is optional, stable, reversible, and never overrides authored layouts silently. | M9 |
| R12 | PiP preserves supported caption paths and clearly identifies unsupported overlay modes. | M6 |
| R13 | Screen-reader controls, D-pad focus, keyboard actions, large text, contrast, and reduced motion all work. | M1 |
| R14 | Closed-caption services and roll-up/pop-on/paint-on behavior are preserved when those formats are supported. | M8 |
| R15 | Hot reload/import errors cannot corrupt selection or leave duplicate rendered tracks. | M2 |
| R16 | Caption rendering remains correct during speed changes, frame stepping, rotation, window resize, and video-output changes. | M6 |

## Learning editing and personal viewing

| ID | Requirement and acceptance condition | Work package |
| --- | --- | --- |
| X01 | Android ExoPlayer watched-portion transcripts are searchable and virtualized; selecting a cue seeks to its source start, and an optional filter hides dialogue after the current playhead. Transcript data stays in session memory and covers only captured portions; persistence and cross-provider transcript browsing remain open. | M3 |
| X02 | Copy/select text and dictionary lookup operate on text-backed cues; bitmap tracks offer OCR explicitly. | M7 |
| X03 | Replay current line, auto-pause, sentence loops, and adjustable gaps work with remote and keyboard. | M7 |
| X04 | Save vocabulary/bookmarks with source attribution and optional flashcard export. | M8 |
| X05 | Optional transliteration/ruby/furigana is a distinct derived display, not a rewritten original. | M8 |
| X06 | The full-track cue editor validates text/time changes and keeps a bounded 100-edit undo stack for the active review dialog. After export or successful attachment, the reviewed result is also stored in a bounded device-local per-profile/server-item revision history; earlier results can be re-attached, exported, or deleted. Individual edit operations are not persisted, and history does not sync across devices. | M7 |
| X07 | Waveform/spectrogram and anchor editing are available in an advanced editor. | M7 |
| X08 | Reflow, line breaks, spell checks, and common-error repair are previewable operations. | M7 |
| X09 | Optional removal of SDH descriptions, song lines, or identifiable subtitle ads never mutates the original or defaults on for accessibility users. | M7 |
| X10 | Spoken subtitles/TTS are optional and mixed with explicit ducking/rate controls. | M9 |
| X11 | Multi-view captions follow selected panes with per-pane identity and a readable density limit. | M8 |
| X12 | Watch Together shares compatible assets/corrections only by policy; language, visibility, and output-device offset remain per viewer. | M8 |
| X13 | Companion/second-screen transcript follows the same media clock with reconnection recovery. | M8 |
| X14 | Subtitle screenshots/export include user-selected tracks and preserve HDR handling where supported. | M8 |

## Persistence export and operations

| ID | Requirement and acceptance condition | Work package |
| --- | --- | --- |
| O01 | Imported OpenSubtitles originals are immutable and content-addressed; manifests use staged replacement and backup recovery. Corrected SRT/VTT and safe simple ASS/SSA copies are exportable; richer derived revisions remain open. | M2 |
| O02 | Upload bounded user-selected SRT/VTT/ASS/SSA files to Plex, Jellyfin, and Emby library items; MediaBrowser metadata is explicit while Plex uses its supported title/format upload fields. AI-generated, translated, and audio-aligned SRT results now offer explicit server upload when the active library item and a validated language code are known, then attach locally; server permissions control acceptance. Standalone-source attachment and cross-device distribution remain open. This path is not test-verified or device-qualified. | M2 |
| O03 | Standalone MPV VOD exports corrected SRT/VTT and simple ASS/SSA copies with clipping confirmation. AI-reviewed generated/translated/synchronized cues can be saved as versioned JSON or retained in device-local revision history for active server library items. Up to 12 revisions per item are kept within a 24 MiB per-item and 256 MiB/1000-file global bound; history is profile/item-scoped, can be re-attached/exported/deleted, and is not cross-device. JSON/history retain cue indices, times, operation/language, and available cue-linked Whisper word/token timings. Individual editor undo remains session-only; timed ASS/SSA effects, bitmap formats, and cross-platform server-library export remain unsupported. | M4 |
| O04 | Include selected subtitle assets and required fonts in offline downloads with quota accounting. | M6 |
| O05 | Cross-device sync transfers manifests, corrections, preferences, and selected assets with conflict handling. | M8 |
| O06 | Model packages have hashes, sizes, task/language metadata, compatibility, update rollback, and licenses. | M4 |
| O07 | Backend probing executes a real model smoke test; installed hardware names alone never enable a feature. | M4 |
| O08 | Shared resource budgets adapt to playback, thermal/power state, memory pressure, and multiview. | M4–M6 |
| O09 | A paired companion exposes capabilities, jobs, cancellation, results, and narrow authenticated media access. | M6 |
| O10 | Cloud/remote processing starts only under configured policy and reports cost/quota/failure states. | M5 |
| O11 | Logs avoid credentials and full transcript text by default. Inference summaries can identify the requested backend, runtime-reported provider/device, and CPU fallback; they do not expose per-operation GPU/NPU placement. Device qualification still requires target hardware runs and measured result reports. | M0 |
| O12 | Malformed subtitles, fonts, archives, and model files are bounded and parser-fuzzed. PR #53 bounds local ZIP, plain TAR, and gzip-compressed TAR inputs and entries; rejects unsafe archive paths and symlinks; checks ZIP resource bounds before expansion, gzip output before TAR decoding, and TAR headers before decode; and never extracts using archive-controlled paths. Parser fuzzing remains open. | M2–M6 |
| O13 | Cast/external-player handoff exports compatible subtitles or offers explicit server burn-in; local overlays are not reported as delivered. | M8 |
| O14 | Provider APIs respect quotas, retries, cancellation, and account boundaries; no executable provider scripts from subtitles. | M2 |
| O15 | Cross-source subtitle search/transcription uses current source leases and handles renewable URLs without cache identity churn. | M4 |
| O16 | Benchmarks record ASR accuracy, timing, stability, end-to-end latency, frame drops, memory, power, and fallback behavior. | M0–M9 |

## Advanced research and optional features

| ID | Experiment and honest completion boundary | Work package |
| --- | --- | --- |
| E01 | OCR PGS/VobSub into editable text while preserving cue images and allowing uncertainty correction. | M7 |
| E02 | Extract burned-in captions using crop/detection, temporal tracking, OCR, and deduplication. | M9 |
| E03 | Translate signs/on-screen text with stable positioning and separate dialogue/sign roles. | M9 |
| E04 | Remove or cover burned text before translated overlay; masking is feasible, exact background recovery is not guaranteed. | M9 |
| E05 | Separate overlapping voices and emit parallel speaker cues; score errors independently of single-speaker ASR. | M9 |
| E06 | Use visual speech/scene context to disambiguate uncertain audio; do not turn guessed dialogue into verified captions. | M9 |
| E07 | Ensemble models or second-pass rescoring improve selected uncertain spans if evaluation proves benefit. | M9 |
| E08 | Caption completeness scoring detects likely gaps without declaring every silent interval an omission. | M7 |
| E09 | Personalized vocabulary and optional local model adaptation improve names/accents without degrading other content. | M9 |
| E10 | Karaoke word highlighting and lyric timing distinguish singing from ordinary dialogue. | M8–M9 |
| E11 | Accessibility sound-event descriptions and spatial direction use evaluated audio evidence, separate from dialogue. | M9 |
| E12 | Optional subtitle-driven dubbing/voice synthesis is a separate audio product with timing and mixing requirements. | M9 |

# 10 How far to build from scratch

**Confidence high:** no assembly rewrite is required to deliver the core plan. The hard problems are source access, clocks, alignment, model behavior, cross-platform rendering, and lifecycle correctness. Machine code can accelerate a proven bottleneck; it cannot restore missing speech, reveal future live audio, or provide an OS API that the platform does not expose.

| Layer | Initial choice | When custom work is justified |
| --- | --- | --- |
| Container/audio decoding | Existing engine/FFmpeg integration and a controlled analysis decoder | A needed PCM tap, passthrough-safe parallel decode, seek/discontinuity support, or missing native bridge |
| Subtitle decoding/rendering | Existing libass/mpv/native paths; bounded parser for editable text views | Required format fidelity, multi-track limitation, dynamic cue injection, or a renderer bug proven by fixtures |
| Global/affine synchronization | VAD, signal correlation, robust fitting; compare against ffsubsync | Native/mobile packaging, predictable latency, selected-audio support, or measurable accuracy gains |
| Piecewise alignment | Evaluate alass and implement a compatible internal timeline representation | Missing edit semantics, licensing/integration constraints, or memory/performance requirements |
| ASR inference | whisper.cpp and optional specialized backends | Unsupported operators/device, excessive copies, scheduling constraints, or proven kernel bottleneck |
| Translation | Existing local model/runtime adapters | Subtitle-specific fine-tuning, terminology constraints, structural decoding, or unavailable language coverage |
| OCR | Tesseract/PaddleOCR/native OCR candidates evaluated on subtitle crops | Temporal consistency, stylized fonts, bitmap antialiasing, or constrained device deployment [W37] |
| CPU optimization | Compiler optimization and dispatched AVX2/AVX-512/NEON intrinsics | Profiling identifies a hot resampler, FFT, quantized matrix multiply, or alignment kernel |
| GPU optimization | Vulkan/Metal/HIP/CUDA libraries and existing inference kernels | Fused attention/GEMM, quantization, persistent buffers, or transfer reduction has measured benefit |
| NPU integration | Vendor compiler/runtime with supported static/quantized graphs | Partitioning/export work and custom supported operators where the SDK permits; no assumed raw NPU instruction interface |
| Training a new model | Research milestone only | Existing models fail a defined language/domain requirement and a suitable dataset, evaluation protocol, compute budget, and distribution path exist |

Any custom assembly/kernel implementation keeps a portable reference path and differential tests. Dispatch by capabilities, validate numerical drift and transcript quality, and retain a safe fallback. Put effort into end-to-end bottlenecks before theoretical peak TOPS. Decoder attention/KV cache behavior, graph partition copies, first-run compilation, and memory bandwidth can dominate practical NPU/GPU speed.

A ground-up alternative remains possible: implement feature extraction, tokenizer, encoder/decoder, quantized tensor runtime, VAD, alignment, translation, OCR, renderer, and model distribution. It is a much larger program and still requires trained weights and quality evaluation. Keep this as an escalation route for demonstrated deficiencies, not a dependency for the first usable release.

# 11 Dependency-aware execution map

M0–M9 describe the full authorized scope. Their ordering records technical dependencies and reduces rework; it is not a release plan, a gate to defer later requirements, or a request for separate approval. Work should continue across packages in parallel wherever interfaces permit, with commits grouped by complete, reviewable behavior. Complexity describes engineering scope, not a calendar promise. Confidence in the dependency order is high; implementation duration is unknown before native extraction and model-runtime spikes.

| Work package | Concrete output | Dependencies and exit gate | Complexity |
| --- | --- | --- | --- |
| M0 Source reconciliation and regression baseline | Rebase the inventory to current main; reconcile PRs #40/#43; write capability matrix; identify actual mpv/native build revisions; establish fixtures and baseline tests. | No feature claims based only on README. Existing source/server/secondary/offset paths remain intact. | Medium |
| M1 Existing feature completion | Exact offset entry, MPV cue-step alignment, independent MPV secondary delay, bounded MPV text-subtitle drift calibration, expanded in-player style controls, and truthful backend capability states. | Build on current track and preference owners. Validate state rollback, scope reset, large text and TV focus. | Medium |
| M2 Durable assets and manual repair | Shared session/store, file import/provider integration, edition binding, anchor/affine repair, previews, undo, export scaffolding. | Preserve originals and source identity across remote URL changes, downloads, profiles and restarts. | Large |
| M3 Automatic sync and transcript | PR #53 adds WAV-file ASR alignment, bounded monotonic text matching, robust global offset/rate, and optional piecewise offset repair. Playback audio extraction, transcript reference, and durable jobs remain open. | Held-out timing validation, confidence/refusal, discontinuity tests, no playback stalls. | Large |
| M4 CPU and accelerated subtitle generation | PR #53 integrates multilingual whisper.cpp for CPU, optional compiled desktop CUDA/Vulkan, and rolling Android ExoPlayer VOD PCM capture. The Tizen package source now also builds the CPU bridge and exposes its player PCM tap; the Tizen build and TV evidence are pending. Sherpa Moonshine offers Core ML/QNN/RKNN provider requests. Full-file VOD read-ahead, durable jobs, remaining player capture, and physical GPU/NPU qualification remain open; backend names are best-effort requests and do not prove per-operation placement. | Real audio becomes a correct selectable subtitle; seeks/audio switches/stale results/passthrough work. Benchmark and report each target CPU/GPU/NPU device on supported hardware. | Very large |
| M5 Translation and accurate timing | PR #53 adds ML Kit cue translation on eligible phones/tablets, optional local Argos desktop cue translation, and Whisper speech-to-English. Glossaries, bilingual output, forced alignment, richer review, and optional configured remote providers remain open. | At least declared language pairs pass linguistic review; tags/names/numbers survive; failures preserve source output. | Large |
| M6 Live captions and device expansion | Android ExoPlayer VOD now has opt-in rolling CPU captions. Tizen source includes an equivalent native PCM and CPU Whisper path but requires a private package build and TV run. True-live/DVR and delayed-live modes, remaining player audio taps, companion processing, Metal/OpenVINO/AMD NPU qualification, and HDR/PiP/offline integration remain open. | Each device/runtime independently measured; local models never block media deadlines. TV clients can use precomputed/companion output without pretending to run locally. | Very large |
| M7 Advanced repair and editing | PR #53 adds text-anchor-derived piecewise timing repair. Bitmap OCR, waveform editor, selected-range regeneration, diarization, gap detection, unmatched-span maps, and content transformations remain open. | Edited-cut/overlap/OCR quality evaluation; explicit uncertainty and reversible operations. | Very large |
| M8 Ecosystem and learning | Cast/external export, cross-device sync, multi-view/watch-together, learning tools, broader caption formats, audio-only transcripts. | End-to-end receiver/device tests and conflict recovery; per-viewer settings remain independent. | Large |
| M9 Research extensions | Burned-caption extraction/removal, scene-aware placement, speech separation, audiovisual disambiguation, custom kernels/models, sound captions and optional dubbing. | Each experiment has its own quality threshold and off switch; no blanket promise of success. | Research |

## Concrete change map

Proposed new paths below are names to create, not claims that they already exist.

| Work package | Existing owners to modify | Proposed additions | Completion demonstration |
| --- | --- | --- | --- |
| Capability reporting | `lib/mpv/player/player.dart`, `player_base.dart`, platform players | `lib/subtitles/subtitle_capabilities.dart` (broader matrix remains planned) | PR #53 advertises local import formats per backend: mpv supports its existing set; ExoPlayer supports SRT/ASS/SSA/VTT on VOD; Tizen/webOS support bounded SRT/VTT overlays. The picker follows the set. Unsupported calls cannot falsely succeed. |
| Domain and asset identity | `subtitle_preference.dart`, `playback_subtitle_resolver.dart`, `track_manager.dart`, `SourcePlayback` | `lib/subtitles/models/`, `subtitle_session.dart`, `subtitle_asset_store.dart` | MPV standalone VOD stores imported OpenSubtitles assets and delay/rate corrections by profile, edition, source-file fingerprint, subtitle digest, and selected audio; server-library attachment and main-library correction identity remain open. |
| UI completion | `track_sheet.dart`, `subtitle_style_sheet.dart`, `subtitle_styling_screen.dart`, `sync_offset_control.dart`, `video_settings_sheet.dart` | Reusable timing/analysis/status widgets under the existing video-control hierarchy | All actions work by touch, keyboard, D-pad, and screen reader; no extra main navigation branch. |
| Provider orchestration | `open_subtitles_client.dart`, both search sheets, backend adapters, `_fetchPreferredSubtitleIfNeeded` | `subtitle_discovery_service.dart`, provider capability/result metadata | Existing searches still work; exact-match/role/provenance selection is deterministic and cancellation safe. |
| Native analysis source | Player native bridges, Android `ExoPlayerCore.kt`/plugin, source transport/playback | `native/subtitle_analysis/` or a repository-consistent native package; versioned C ABI | Selected source audio yields correctly timestamped PCM without altering audible output. |
| Timing engine | `PlayerSyncOffsets`, scoped preferences, player adapters | `lib/subtitles/timing/`, native VAD/alignment worker as needed | Known offsets/drift/cuts recover or refuse; both tracks and originals remain independently reversible. |
| Inference and model manager | Settings, download/storage infrastructure, runtime packaging | `lib/subtitles/inference/`, `model_registry.dart`, native backend adapters | Actual packaged CPU/Vulkan model works after a clean install; cancelled downloads do not appear installed. |
| Translation | Subtitle documents and inference manager | `lib/subtitles/translation/`, glossary/revision store | Multilingual output is valid, aligned, editable, and traceable to source cues. |
| Live renderer | `PlayerNative`, ExoPlayer text/ASS integration, Tizen/webOS adapters where feasible | Bounded cue stream API and renderer acknowledgements | Caption finalization/seek/discontinuity causes no duplicates, stale lines, or leaked memory. |
| Companion | Existing pairing/credential/transport conventions after code audit | `tools/subtitle-companion/` and client adapter, or equivalent repository layout | Pair, probe, submit, cancel, resume, and fetch results; disconnected jobs cannot mutate another profile. |
| Persistence and export | Downloads, source files, profile lifecycle | Derived-asset manifests, exporters, conflict handling | MPV standalone exports affine-retimed SRT/VTT and simple ASS/SSA, refusing event timing features it cannot preserve; it confirms cues removed before time zero. Bitmap export, embedded provenance, and source-download packaging remain. |

The inference ABI should expose capability discovery, model creation, buffered audio submission, event polling, cancellation, and destruction. Return structured errors and actual backend placement. Keep the ABI stable across Flutter and platform implementations. Native workers own long-lived tensor buffers. Dart owns high-level job state and uses bounded event batches.

For a companion, define `capabilities`, `createJob`, `appendAudio`, `events`, `cancelJob`, and `result` semantics with idempotent job creation and version negotiation. Permit either narrow renewable media access or client-decoded PCM. Do not copy whole server credentials to the companion. Remote results carry the same digests and epochs as local ones. Network failure leaves existing subtitle playback functioning.

## First vertical slice

The initial integrated slice now has explicit primary/secondary selection, independent manual offset, one-cue alignment, two-anchor preview/undo, persistent per-audio correction, corrected SRT/VTT and safe ASS/SSA export, bounded ZIP/plain TAR subtitle import for backends with local subtitle support, and text-candidate preview before standalone OpenSubtitles apply. The next alignment path is selected-audio VAD on a local file using the same correction identity. CPU ASR then turns selected audio into a reusable timed asset, with Vulkan qualification and platform adapters proceeding against the same job/asset contracts. These connected work streams expose the difficult clock/identity/renderer boundaries early without narrowing the overall scope.

Do not start with NPU dispatch, OCR, or a large language-model editor. Those features depend on the same correct subtitle document, source clock, and job lifecycle.

# 12 Verification and release gates

Existing test files are regression anchors, not evidence that this planning task ran the suite. Use the repository's pinned SDK and native toolchain. `AGENTS.md` requires compatible private ephemeral JIT runners for build, test, scan, packaging, and release work; GitHub-hosted fallback is not authorized. [C23]

| Area | Existing anchors to retain | Required additions |
| --- | --- | --- |
| Identity and selection | `test/services/subtitle_preference_test.dart`, `track_selection_service_test.dart`, `track_manager_test.dart`, `playback_subtitle_resolver_test.dart` | Derived assets, audio-switch invalidation, wrong-cut rejection, explicit-Off fallback suppression, late native arrival |
| Timing | `test/services/player_sync_offsets_test.dart`, `scoped_player_prefs_test.dart`, `test/widgets/video_controls_sync_offset_display_test.dart` | Secondary offsets, affine/piecewise transforms, sign conventions, speed/transcode/multipart/discontinuity maps |
| Track UI | `test/widgets/track_sheet_test.dart`, `subtitle_search_sheet_test.dart`, `standalone_subtitle_search_sheet_test.dart` | Explicit secondary controls, full style preview, unsupported actions, role metadata, no-op backend refusals |
| Native behavior | `test/mpv/track_list_secondary_subtitle_test.dart`, `player_native_bridge_test.dart`, `player_android_subtitle_visibility_test.dart`, `player_tizen_test.dart` | Cue streaming, PCM buffering/cancellation, actual model placement, worker failure and native memory lifecycle |
| Source playback | `test/sources/source_player_accessibility_test.dart`, source-playback tests | Durable derived asset attachment and export, renewable transport, no cross-profile leakage |
| Android rendering | `MpvSubtitleGeometryTest.kt`, `SubtitleCueLayoutTest.kt`, `SubtitleViewLayoutTest.kt`, `PgsCompositionParserTest.kt`, external subtitle identity tests | ASS/PGS overlap, independent tracks, audio-delay versus presentation-calibration separation |
| Downloads | Download manager/storage tests | Model/asset partial download recovery, checksums, quotas, font packages, stale-job commit refusal |

Build a reproducible, appropriately licensed fixture corpus: clean and noisy speech; silence and music; accented speech; code-switching; low-resource languages; whispers/shouts; singing; two simultaneous speakers; translations that paraphrase; dubbed audio; forced/sign-only tracks; intentional overlapping ASS; Arabic/Hebrew/Indic/CJK text; PGS/VobSub; incomplete/corrupt files; and adversarially long cues/attachments. Include generated timing fixtures with exact known truth, then separately annotated real clips. Keep development tuning and acceptance sets separate.

Timing tests cover positive/negative offsets, frame-rate drift, source start time, time stretching, discontinuous edits, dropped/inserted scenes, stacked files, transcode seek offsets, long-duration rounding, HLS discontinuities, live-edge shifts, DVR eviction, and rapid backward/forward seeking. Test exports against the canonical transformed document, not only the implementation's own intermediate result.

Lifecycle tests cover play/pause/EOS, episode advance, source/version changes, audio/subtitle changes during a running job, profile deletion/switch, expired credentials, app backgrounding, sleep/resume, output-device changes, PiP, cast handoff, network loss, OOM/device loss, thermal throttling, model checksum mismatch, and a companion that returns stale/out-of-order events.

Rendering qualification needs physical outputs: normal/large text and TV safe areas; SDR/HDR; video-plane versus Flutter overlays; ASS and bitmap opacity/position; subtitle luminance; PiP; and real receivers. A screenshot or unit test does not prove HDR brightness, frame cadence, audio passthrough, or receiver-side captions.

Publish a benchmark record per qualified tuple: app commit, native/runtime/model revision and hashes, OS/driver, CPU/GPU/NPU, precision, language, media characteristics, playback speed, concurrency, cold-start time, p50/p95 latency, sustained RTF, WER/CER, cue timing, caption stability, memory/VRAM, energy/thermal behavior, playback frame drops/audio underruns, and fallback reason. Keep human quality review for translation and SDH semantics; automated metrics alone miss meaning-changing errors.

## Definition of done

Each requirement receives one status: implemented and tested; implemented but device-unqualified; experimental; deferred with dependency/reason; or unsupported with an alternative. Code complete requires a connected user-visible path, persistence/lifecycle behavior, meaningful tests, and packaged dependencies. Device-qualified additionally requires actual playback and inference on that platform. An interface, TODO, setting, or mocked backend is not the completed feature.

No silent success from an unsupported backend. No silent cloud fallback. No unbounded audio/model queues. No mutation of original subtitles. No stale transcript following a seek/audio/profile change. No generic all-platform support claim from one successful desktop run.

# 13 Implementation handoff and remaining qualification

> PR #77 carries the current subtitle workflows: local WAV-based CPU ASR and translation, optional GPU/NPU provider requests with CPU fallback, automatic timing/cut repair, server-side subtitle upload, expanded drop/share import, and MPV cue replay. Android ExoPlayer PCM capture is implemented; Tizen native capture and CPU Whisper packaging are wired in source but still need a private-JIT build and TV qualification. MPV capture remains blocked on new published binaries, and webOS/browser do not expose a supported player PCM path here. Preserve `TrackManager`, `TrackSelectionService`, `PlaybackSubtitleResolver`, `SubtitlePreference`, scoped offsets, existing rendering, downloads, server selection, and source playback ownership. Keep originals, gate output attachment by backend capability, and guard provider claims: GPU/NPU placement and device performance are not qualified. Remaining catalogue requirements must be tracked separately from these delivered paths. Respect the private-JIT runner policy; source syntax checks passed in this workspace, but no private build or physical-device validation was run.

# 14 Source register

Repository links below are pinned to the audited commit except PRs and upstream issues. External documentation is current at retrieval; model/runtime/platform support must be pinned again during implementation. Confidence is high for quoted source behavior, moderate for inferred product opportunities, and unknown for unmeasured performance. Issue reaction counts are snapshots, not a global popularity ranking.

## PlezyNG source references

- C01 — [Player interface and factory][C01].
- C02 — [Track sheet including dual selection and local import][C02].
- C03 — [Native mpv player and secondary selection][C03].
- C04 — [ExoPlayer Dart backend][C04]; [Tizen backend](https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/mpv/player/platform/player_tizen.dart); [webOS backend](https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/mpv/player/platform/player_webos.dart).
- C05 — [Timing controls][C05].
- C06 — [Applied offset state][C06]; [scoped preferences](https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/services/scoped_player_prefs.dart).
- C07 — [Subtitle identity and intent][C07]; [track matching and selection](https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/services/track_selection_service.dart).
- C08 — [Track lifecycle][C08]; [playback subtitle resolver](https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/services/playback_subtitle_resolver.dart).
- C09 — [Server subtitle-search UI][C09]; [Jellyfin and Emby search/download adapter](https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/services/jellyfin_client/parts/subtitle_search.dart).
- C10 — [Preferred-language automatic fetch and playback opening][C10].
- C11 — [Direct OpenSubtitles client][C11]; [standalone search sheet](https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/screens/sources/standalone_subtitle_search_sheet.dart).
- C12 — [Source playback and temporary subtitle lifetime][C12].
- C13 — [Current in-player subtitle appearance sheet][C13].
- C14 — [Full subtitle appearance settings][C14].
- C15 — [Android ExoPlayer core][C15]; [ASS atlas pipeline](https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/android/libass/src/main/java/com/edde746/plezy/libass/media/widget/AssSubtitleAtlasPipeline.kt); [ASS latency calibration](https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/android/app/src/main/kotlin/com/edde746/plezy/exoplayer/AssLatencyCalibrator.kt).
- C16 — [Download manager and per-part subtitle enrichment][C16].
- C17 — [Track visibility and burned-subtitle handling][C17].
- C18 — [DV native-port qualification][C18]; [DV engine research](https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/tools/dv-engine/README.md).
- C19 — [Settings and defaults][C19]; [README baseline](https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/README.md).
- C20 — [Open motion-clarity PR 40][C20].
- C21 — [Open playback-parity PR 43][C21].
- C22 — [Upstream request for in-player subtitle styling][C22].
- C23 — [Runner policy][C23]; [design contract](https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/DESIGN.md); [UX contract](https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/UX-CONTRACT.md).

## External primary sources

- W01 — [Plex auto-sync requirements and limitations][W01].
- W02 — [Infuse product and format support][W02].
- W03 — [Infuse multiple-subtitle request thread][W03].
- W04 — [Infuse automatic-sync request thread][W04].
- W05 — [mpv manual, subtitle options and commands][W05].
- W06 — [IINA subtitle-provider API][W06]; [plugin catalogue](https://iina.io/plugins/).
- W07 — [Kodi subtitle configuration][W07]; [language preferences](https://kodi.wiki/view/Settings/Player/Language); [subtitle directories and HDR brightness](https://kodi.wiki/view/Subtitles).
- W08 — [VLC synchronization controls][W08].
- W09 — [Videolabs AI plugins and early-access status][W09].
- W10 — [Jellyfin Desktop dual-subtitle request][W10].
- W11 — [Historical Jellyfin Android TV offset request][W11].
- W12 — [Emby automatic subtitle downloads][W12]; [manual subtitle downloads](https://emby.media/support/articles/Manual-Subtitle-Downloads.html).
- W13 — [MPC-HC features][W13].
- W14 — [Subtitle Edit overview][W14]; [speech-to-text engines](https://github.com/SubtitleEdit/subtitleedit/blob/main/docs/features/speech-to-text.md).
- W15 — [Bazarr subtitle processing][W15]; [Whisper provider](https://wiki.bazarr.media/Additional-Configuration/Whisper-Provider/); [translation providers](https://wiki.bazarr.media/Additional-Configuration/Settings/Providers/).
- W16 — [Language Learning with Netflix controls][W16].
- W17 — [Microsoft live captions][W17].
- W18 — [Chrome live captions and translation][W18].
- W19 — [Upstream Plezy subtitle size/position report][W19]; [Infuse overlapping-cue report](https://community.firecore.com/t/external-subtitles-overlap-not-working/47722).
- W20 — [ffsubsync implementation and algorithm][W20].
- W21 — [alass language-agnostic alignment][W21].
- W22 — [WhisperX alignment and limitations][W22].
- W23 — [Whisper model/task documentation][W23].
- W24 — [WhisperStreaming stability method and successor note][W24].
- W25 — [whisper.cpp native and accelerated backends][W25].
- W26 — [sherpa-onnx local and streaming ASR][W26].
- W27 — [faster-whisper CPU/CUDA implementation][W27].
- W28 — [FFmpeg Whisper filter][W28].
- W29 — [Argos Translate local translation][W29].
- W30 — [NLLB model card and intended use][W30].
- W31 — [AMD 9950X3D specifications][W31].
- W32 — [AMD current Linux support requirements][W32].
- W33 — [WhisperKit Core ML models and current Argmax repository pointer][W33].
- W34 — [OpenVINO GenAI NPU and Whisper support][W34].
- W35 — [ONNX Runtime QNN execution provider][W35].
- W36 — [AMD Ryzen AI Whisper NPU integration and OS limit][W36].
- W37 — [PaddleOCR project][W37].

[C01]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/mpv/player/player.dart
[C02]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/widgets/video_controls/sheets/track_sheet.dart
[C03]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/mpv/player/player_native.dart
[C04]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/mpv/player/platform/player_android.dart
[C05]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/widgets/video_controls/widgets/sync_offset_control.dart
[C06]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/services/player_sync_offsets.dart
[C07]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/services/subtitle_preference.dart
[C08]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/services/track_manager.dart
[C09]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/widgets/video_controls/sheets/subtitle_search_sheet.dart
[C10]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/screens/video_player/parts/playback_open.dart
[C11]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/services/open_subtitles_client.dart
[C12]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/sources/source_playback.dart
[C13]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/widgets/video_controls/sheets/subtitle_style_sheet.dart
[C14]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/screens/settings/subtitle_styling_screen.dart
[C15]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/android/app/src/main/kotlin/com/edde746/plezy/exoplayer/ExoPlayerCore.kt
[C16]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/services/download_manager_service.dart
[C17]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/widgets/video_controls/parts/track_controls.dart
[C18]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/docs/maintainers/dv-native-ports.md
[C19]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/lib/services/settings_service.dart
[C20]: https://github.com/snapetech-org/PlezyNG/pull/40
[C21]: https://github.com/snapetech-org/PlezyNG/pull/43
[C22]: https://github.com/edde746/plezy/issues/689
[C23]: https://github.com/snapetech-org/PlezyNG/blob/9e64808223fb67d509d806a46eedc20a1ad02a5c/AGENTS.md
[W01]: https://support.plex.tv/articles/auto-sync-subtitles/
[W02]: https://firecore.com/infuse
[W03]: https://community.firecore.com/t/render-multiple-subtitles-at-once/19588
[W04]: https://community.firecore.com/t/auto-sync-subtitles/39253
[W05]: https://mpv.io/manual/stable/
[W06]: https://docs.iina.io/pages/subtitle-providers
[W07]: https://kodi.wiki/view/Settings/Player/Subtitles
[W08]: https://docs.videolan.me/vlc-user/desktop/3.0/en/basic/settings/adjustmentsandeffects.html
[W09]: https://videolabs.io/store/ai-plugins/
[W10]: https://github.com/jellyfin/jellyfin-desktop/issues/1223
[W11]: https://github.com/jellyfin/jellyfin-androidtv/issues/1234
[W12]: https://emby.media/support/articles/Automatic-Subtitle-Downloads.html
[W13]: https://github.com/clsid2/mpc-hc
[W14]: https://subtitleedit.github.io/subtitleedit/overview.html
[W15]: https://wiki.bazarr.media/Additional-Configuration/Settings/Subtitles/
[W16]: https://languagelearningwithnetflix.com/instructions.html
[W17]: https://support.microsoft.com/en-us/accessibility/windows/use-live-captions-to-better-understand-audio
[W18]: https://support.google.com/chrome/answer/10538231?hl=en
[W19]: https://github.com/edde746/plezy/issues/1442
[W20]: https://github.com/smacke/ffsubsync
[W21]: https://github.com/kaegi/alass
[W22]: https://github.com/m-bain/whisperX
[W23]: https://github.com/openai/whisper
[W24]: https://github.com/ufal/whisper_streaming
[W25]: https://github.com/ggml-org/whisper.cpp
[W26]: https://k2-fsa.github.io/sherpa/onnx/index.html
[W27]: https://github.com/SYSTRAN/faster-whisper
[W28]: https://ffmpeg.org/ffmpeg-filters.html#whisper
[W29]: https://github.com/argosopentech/argos-translate
[W30]: https://huggingface.co/facebook/nllb-200-distilled-600M
[W31]: https://www.amd.com/en/products/processors/desktops/ryzen/9000-series/amd-ryzen-9-9950x3d.html
[W32]: https://github.com/ROCm/rocm-install-on-linux/blob/develop/docs/reference/system-requirements.rst
[W33]: https://huggingface.co/argmaxinc/whisperkit-coreml
[W34]: https://docs.openvino.ai/2026/openvino-workflow-generative/inference-with-genai/inference-with-genai-on-npu.html
[W35]: https://onnxruntime.ai/docs/execution-providers/QNN-ExecutionProvider.html
[W36]: https://ryzenai.docs.amd.com/en/latest/whisper_cpp.html
[W37]: https://github.com/PaddlePaddle/PaddleOCR
[W38]: https://pub.dev/packages/flutter_whisper_ggml
