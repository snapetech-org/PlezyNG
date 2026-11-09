# Integrated music and car experience

Requested 2026-11-09. Build the complete Plexamp feature-parity scope into
Pleazyng on one PR branch. Music capabilities remain integrated into normal
Discover, Libraries, Search, details, playlists, Downloads, Now Playing and
Settings on every supported platform. Native car surfaces use the same catalog,
queue and playback session. This is one implementation worklist, not a staged
release or a timetable.

## Architecture

- Extend MusicPlaybackService, MusicQueueController, MusicSessionStore and the
  existing Player.audio backends; native surfaces must not own competing queues.
- Keep PlaybackCoordinator authoritative for music/video/file/narration and
  multiview audio ownership. Preserve profile and server-qualified identities.
- Use existing screens, action menus, typed preferences, downloads and provider
  transports. Add new routes only for operations with no suitable existing form.
- Android Auto requires a native media browse/session service. CarPlay requires
  native templates and a signed audio entitlement. AAOS media support must retain
  the existing parked-video restrictions for non-audio content.
- Treat offline files, cached metadata, recipes and pending music events as
  profile-owned durable data. Never store access tokens in media IDs or links.
- Implement and test supported behavior; record unavailable API, provisioning or
  physical-device evidence separately. Do not count an unavailable feature as
  completed parity or a source-only test as device qualification.

## Full scope

| ID | Feature | Required behavior |
| --- | --- | --- |
| B01 | Libraries, artists, albums and tracks | Extend the same routes; preserve server/profile identity, filters, large-library paging and all input modes. |
| B02 | Global and in-library search | Add consistent music scopes, recent queries and playable results from authorized sources; return to the existing detail/player routes. |
| B03 | Discography and album categories | Keep singles, EPs, live and compilation distinctions where data supports them; never infer false categories from titles alone. |
| B04 | Track detail, credits and editions | Inventory credits, labels, versions, codec, dates and contextual actions in the reference clients; expose supported fields without merging different recordings. |
| B05 | Ratings, favorites and listening state | One shared action service, offline writes and provenance; do not silently translate a heart into an arbitrary star score. |
| B06 | Regular playlist management | Close create/rename/delete/reorder, multi-select, duplicate occurrences, sharing and artwork gaps against the reference checklist. |
| B07 | Smart playlists and filter editing | Reuse filter forms for rule creation/editing, preview, sorting, limits and save-as; preserve rule-based semantics and permissions. |
| B08 | Collections, sharing and artwork | Qualify music collections, authorized artwork updates and share links; shared read-only libraries must remain read-only. |
| B09 | Customizable music home | Add music shelves/pins, order/visibility controls, recent and rediscovery rows; a Music shortcut opens this filtered view. |
| B10 | Anniversaries and recent rediscovery | Add album anniversaries and listening-based rediscovery in Discover, with date precision and timezone handling. |
| P01 | Gapless playback | Prove continuous PCM for supported same-rate fixtures; cover encoder delay/padding, mixed formats, skips and offline transitions. |
| P02 | Sweet Fades behavior | Implement reference-matched overlap, timing and album exceptions in the native audio layer; cache required analysis for offline use. |
| P03 | Loudness leveling | Separate music gain/peak handling from video compression; support album versus shuffle context, clipping protection and missing-analysis behavior. |
| P04 | Advanced pre-caching | Add bounded memory/disk look-ahead, mobile-data limits, cancellation and cache diagnostics; prove uninterrupted playback for the configured buffer window. |
| P05 | Streaming and conversion quality | Separate Wi-Fi/mobile/remote/download policies where required; validate original, transcode, format fallback and honest reported output. |
| P06 | Queue edits, shuffle and repeat | Inventory Play Next/Up Next/Back To semantics; distinguish duplicate occurrences, preserve manual insertions and implement reversible shuffle behavior. |
| P07 | Persistent large queues | Persist queue entries/recipe/cursor separately with paged history; preserve full logical queue and shuffle state without loading the library into RAM. |
| P08 | Album-aware playback | Keep ordered album blocks, disc boundaries and skip-album behavior; generated stations must not fragment albums unless requested. |
| P09 | Timed/plain lyrics | Qualify seeking, timing offsets and authorized offline copies; distinguish unavailable text from network errors. |
| P10 | Waveform/seek-print navigation | Add bounded cached seek-print data and accessible seek controls; retain a plain timeline when analysis is unavailable. |
| P11 | Sleep timer | Verify reference presets and final-track behavior under fades, remote playback and queue regeneration. |
| P12 | Ten-band EQ | Integrate the same form into music settings; validate music-engine application, presets, preamp/headroom and supported native TV implementations. |
| P13 | Headphone/output EQ presets | Add searchable, versioned presets and per-output assignments; verify dataset provenance and measured gain behavior. |
| P14 | Sample-rate matching and DAC output | Implement supported output-rate policies and route-change recovery; report actual hardware rate. Bit-perfect claims require captured evidence with DSP off. |
| P15 | Formats, multichannel and DSD | Freeze reference format behavior, test FLAC/ALAC/AAC/MP3/Opus/DSD and channel layouts; distinguish conversion from native/DoP output. |
| P16 | Signal-path and quality information | One Now Playing information sheet shows source, transcode, DSP, output rate/channels and uncertainties; never infer lossless output from a FLAC source badge. |
| P17 | Background playback and OS controls | Make service startup independent of a mounted screen; qualify lock screen, media keys, interruption/ducking and OS-requested resume. |
| D01 | Station/radio families | Inventory library, artist, track, album, mood/style/genre/era and other reference stations; implement rolling sessions with history and explicit seed provenance. |
| D02 | Autoplay continuation | Extend only the generated tail; avoid repeats, respect manual queue edits, exclusions, missing items and offline limits. |
| D03 | Sonic similarity and related tracks | Add authorized similarity requests, provenance and Related in existing details/Now Playing; never relabel a genre-only result as sonic analysis. |
| D04 | Artist and album mix builders | Add multi-seed selection, tuning, preview, play/save/download and edit; persist a reusable recipe, not just a transient result list. |
| D05 | Personalized mixes | Consume supported server mixes and history; add recent/historical music rows with bounded loading and empty-state handling. |
| D06 | Sonic Adventure | Create ordered waypoint selection, path length/constraints, preview, regeneration and save; API feasibility and output equivalence are early gates. |
| D07 | Guest DJ modes | Inventory every available reference mode and settings. Implement one session-owned generator with generated-entry labels, cancellation and turn-off behavior. |
| D08 | Sonic Sage / prompt playlists | Resolve proposed tracks to authorized playable IDs; preview missing/ambiguous matches, support regenerate/edit/save, optional provider configuration and clear data-use choice. |
| D09 | Aural Fixations and listening charts | Add music-specific listening events, deduplication and period summaries in Discover; validate play-count/skip criteria, timezones and offline reconciliation. |
| D10 | Server analysis readiness | Show analysis missing/pending, permissions, unavailable API and unsupported backend separately; expose admin actions only with verified authority. |
| O01 | Album, track and playlist downloads | Reuse download ownership/storage; qualify coherent audio, metadata/artwork and exact playable representation manifests. |
| O02 | Download mixes, stations and rules | Support duration/count/space budgets, refresh cadence and Wi-Fi policy; materialize radio recipes into finite offline snapshots. |
| O03 | Full offline music experience | Bundle searchable metadata, lyrics where permitted, artwork, analysis and saved recipes; car cold start must work without server discovery. |
| O04 | Offline plays and rating reconciliation | Add music-specific idempotent events and ordered rating writes; preserve pending edits during download refresh and concurrent device changes. |
| O05 | Cache and download lifecycle | Keep disposable cache separate from pinned downloads; quota eviction, partial-file cleanup, low-disk recovery and provider revocation must preserve ownership. |
| U01 | Visualizers | Retain and qualify the current engine; provide reference-equivalent visualizer controls with original visuals, reduced motion and clean car suppression. |
| U02 | Artwork backgrounds and themes | Implement comparable artwork-reactive controls within Pleazyng styling; preserve contrast, OLED/light modes and user overrides. |
| U03 | Phone, tablet, desktop and TV layouts | Extend the same player; desktop panes/keyboard and TV D-pad remain first-class, including the new Related/DJ/output actions. |
| U04 | Accessibility and localization | Test all new controls at large text, RTL, screen reader and reduced motion; generated translations are not reviewed language qualification. |
| U05 | Shortcuts, widgets and interaction settings | Freeze keyboard, tray, one-tap, widget and shortcut behavior per reference platform; implement supported controls through the shared command layer. |
| U06 | Links and NFC actions | Share durable music references and write supported NFC actions; resolve account context at use time and never embed server tokens. |
| R01 | Chromecast music | Extend receiver queue, metadata, controls, authentication/reachability handling and progress ownership; expose receiver limits honestly. |
| R02 | AirPlay and system audio routes | Use supported Apple route APIs, route diagnostics and recovery; distinguish system routing from a general AirPlay sender on other OSes. |
| R03 | Remote control versus playback transfer | Separate control target from active output; transfer queue/cursor/modes atomically after receiver acknowledgement, without changing local queue merely on selection. |
| R04 | Headless Raspberry Pi endpoint | Package a managed Linux ARM endpoint using shared contracts, audio engine, persistent state, pairing, updates and diagnostics. |
| R05 | Cross-client interoperability / grouping | Inventory reference endpoint/group controls; verify authorized Plex protocols separately. If synchronization is required, test clock drift/latency, not just multiple play commands. |
| C01 | Apple CarPlay | Add approved audio entitlement, scene templates, browsing/Now Playing, cold launch and one shared session. |
| C02 | Android Auto | Add native media browsing/session transport, browser tree, search, voice and queue actions; bridge existing MPV rather than introduce a competing player. |
| C03 | Android Automotive OS | Provide a compliant media distribution target; separate music allowance from parked-only video/game UI, with independent setup and vehicle qualification. |
| C04 | Phone driving view | Add manual and supported automatic entry, large controls, favorites/offline shortcuts and route-aware exit; OS background-launch limits still apply. |
| C05 | Siri and Android assistant commands | Resolve spoken artist/album/playlist/station names and next/later requests through the same catalog/session; handle ambiguity, lock state and account switching. |
| C06 | Attach, detach and interruption lifecycle | Test wired/wireless projection, selected Bluetooth routes, calls/navigation, process recreation, no-network launch and safe output-loss pause. |
| X01 | Retired and external music services | Exclude retired TIDAL integration from current parity; any new commercial streaming provider needs its own verified API/playback capability and work item. |
| X02 | Non-Plex music sources | Reuse source adapters under common catalog/session contracts; expose genuine backend gaps. Independent sonic analysis is a separately costed extension. |

## Acceptance

Record implementation, automated tests and native/device evidence for each item
in STATUS.md. Exercise normal playback, queue edits, offline cold start, locked
phone, car connection, native controls/voice, interruption and disconnect while
retaining the session. Include codec/audio output fixtures, profile races, large
queues, download recovery, accessibility and all supported package targets.

The parity reference is the public Plexamp feature set reviewed on 2026-11-09.
Freeze installed reference versions when performing device comparison. Retired
TIDAL integrations are not current requirements. Plex-backed sonic functionality
requires accessible authorized analysis/API data; other providers retain their
own capability and authorization boundaries.

## Sources

- [Plexamp features](https://www.plex.tv/plexamp/)
- [Sonic analysis](https://support.plex.tv/articles/sonic-analysis-music/)
- [Plex server API](https://developer.plex.tv/pms/)
- [CarPlay](https://developer.apple.com/documentation/carplay)
- [Android media on cars](https://developer.android.com/media/implement/surfaces/cars)
- [Android car quality](https://developer.android.com/docs/quality-guidelines/car-app-quality)

The initial source assessment used commit
06908c891ba25de05e14e8e2b99a3173aa2ce665. Implementation starts from
a58f9eddfe91c35a939d8fd6445e025eba3be699.
