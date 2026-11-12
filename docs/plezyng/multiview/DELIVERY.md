# Multiview delivery ledger

Current source: main, assessed and remediated through 2026-11-12. Earlier draft-branch
instructions and completion claims in this file have been superseded by the
owner's direct-to-main remediation request. This ledger distinguishes source
implementation from executed platform qualification.

| Area | Current implementation |
| --- | --- |
| Workspace | Profile-scoped live adapters, floating/split/fullscreen layouts, placement history, restore/park/tray actions, one selected audible owner and exclusive gamepad-input leases. Existing routes/services own auth, progress, players and teardown. |
| Video admission | Four native player slots are reserved before asynchronous teardown and retained through native disposal. MPV and Android ExoPlayer have isolated channels for each slot across their supported app targets; Tizen and webOS controllers use their own native player IDs. A fifth session is rejected before player construction. |
| Detached desktop video | macOS lends the retained AVFoundation video and OSD layers to a public AppKit window. Windows reparents the retained mpv video HWND. Linux/Wayland recreates only the existing producer surface's subsurface relationship; render context, decoder and colour objects remain owned. Presents/HDR transactions must drain before reparenting. No media URL or credential is copied to argv, disk or another process. |
| Detached controls | Localized native buttons delegate play/pause and skip intent to the original video/source route. Watch Together, relative-seek accumulation and live capture-buffer policy remain in those owners. Closing the native window returns the plane to its pane; explicit full-route restore waits for successful native attachment. Tokens reject delayed controls; at most 32 intents queue. |
| Window geometry | Profile/slot SHA-256 keys separate geometry without storing profile names or media credentials. macOS uses frame autosave and screen clamping. Windows stores validated bounds and clamps restored windows to an available work area. Wayland persists normal window size; global positioning belongs to the compositor. Persistence updates during movement/resize, so a clean close is not required to retain the last saved geometry. |
| Native lifecycle | Native windows belong to their existing native player plugin. Player/profile teardown closes them before destroying native resources. Parent-widget geometry/visibility cannot hide or resize a detached plane; its latest requested visibility is applied when the plane returns, including parked panes. Source playback persists but does not pause when Flutter loses focus to its native video window. A window close does not create another playback owner or end the media session. |
| Other surfaces | Supported desktop non-video surfaces can move into additional Flutter views on the existing engine. Their original routes/services retain ownership; window messages contain opaque tokens and presentation metadata. Native video keeps its platform-specific plane adapter. TV platforms retain their in-app workspace adapters. |
| Games | Android GameStream/Moonlight and Steam now expose retained native surfaces with separate audio/input ownership and explicit teardown. Android GameStream keeps the original Activity for full-screen playback and admits one live Moonlight connection at a time because its native bridge is process-wide. Its controller handler and virtual controls exist only while that surface owns input; lease loss releases active inputs and destroys handler state and callbacks before another surface can claim the lease. The Android debug compile passed at `7b35413f1fbedf6cc85f9afb9ff5843c9738b74e`, including Moonlight native builds for arm64-v8a, armeabi-v7a, x86 and x86_64. PlatformView frame latency, detach/reattach recovery and physical-device decoder/input/audio behavior still need qualification. |
| Recovery | Profile-local checkpoints retain safe identities, positions and layout. The session tray offers explicit resume or dismissal after restart; resume reauthorizes through the current profile and existing media/source routes. Library video, source audio and readers, including fully cached source editions, use the same owner guards. Checkpoints never store media URLs, credentials, players or provider sessions. Missing workspace checkpointing cannot abort player startup. Games are never launched automatically. |

## Validation

Local focused validation passed 155 tests for workspace/recovery, profile
navigation, source playback and signed catalogs, plus 13 player-startup
regressions after optional checkpoint attachment was corrected. The latter
cover live fallback, display matching, retry UI and ambient-light restoration
without a workspace provider. Native-window calls have deadlines, and the
unresponsive-availability regression passed. Native desktop and device results
remain separately recorded in the [audit ledger](../../security/audit-remediation-2026-11-09.md).

Required platform acceptance remains: detach/reattach each admitted video slot,
resize and move between mixed-DPI/HDR displays, unplug the saved display, exercise
native keyboard/screen-reader controls, close while paused/buffering/seeking,
change profiles during pending commands, and confirm uninterrupted progress with
one audible owner. Linux must also cover in-flight render/HDR transactions and
compositor-driven resize/placement. Release claims require these results at the
packaged source revision.

Wayland reparenting follows the core protocol's rule allowing another
`wl_subsurface` for the same `wl_surface` after its old subsurface object is
destroyed: https://wayland.freedesktop.org/docs/html/apa.html .
