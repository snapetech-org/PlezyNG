# Multiview delivery ledger

Current source: main, assessed and remediated through 2026-11-13. Earlier draft-branch
instructions and completion claims in this file have been superseded by the
owner's direct-to-main remediation request. This ledger distinguishes source
implementation from executed platform qualification.

| Area | Current implementation |
| --- | --- |
| Workspace | Profile-scoped live adapters, floating/split/fullscreen layouts, placement history, restore/park/tray actions, one selected audible owner and exclusive gamepad-input leases. Screen readers can activate a pane to focus it; interactive game panes receive input only after that focus action. Existing routes/services own auth, progress, players and teardown. |
| Workspace audio | Single audible session remains the default. Player-backed video, local source and local music adapters can apply a transient per-session gain multiplier without changing their saved player volume. The workspace exposes an explicit second-stream Mix action only when both live MPV adapters report decoded non-exclusive output on the same nonempty device route; the primary retains focus and the mix is capped at two sessions. Android, iOS/tvOS, Tizen, webOS, remote cast, reader narration and game outputs do not advertise mixing. webOS gain is available only for its app-owned SoLoud audio route; LG video output has no per-session gain. Android/iOS/Tizen gain availability follows their player `setVolume` path. The latest user selection is fenced from stale callback completion or rollback. These are source capability gates, not device qualification. Audio ducking, interruption recovery, TTS gain and shared media-control routing remain open MV11 work. |
| Hidden video | Parking a video pane or promoting another pane to fullscreen sends a pause intent through its existing player owner. Source-video pauses recheck route, player and file ownership when the serialized command starts and after native pause; they preserve an intervening manual pause and cannot pause a replacement source. An explicitly selected audible owner may continue as background audio; default audio ownership does not. Returning to a pane leaves it paused until Play. Watch Together and external playback retain their existing shared/remote transport policy. The session tray still uses a generic Parked label; type-specific paused, ready-to-reopen and game-disconnected status remains open. This is source behavior, not device qualification. |
| Video admission | Four native player slots are reserved before asynchronous teardown and retained through native disposal. MPV and Android ExoPlayer have isolated channels for each slot across their supported app targets; Tizen and webOS controllers use their own native player IDs. A fifth session is rejected before player construction. |
| Detached desktop video | macOS lends the retained AVFoundation video and OSD layers to a public AppKit window. Windows reparents the retained mpv video HWND. Linux/Wayland recreates only the existing producer surface's subsurface relationship; render context, decoder and colour objects remain owned. Presents/HDR transactions must drain before reparenting. No media URL or credential is copied to argv, disk or another process. |
| Detached controls | Localized native buttons delegate play/pause and skip intent to the original video/source route. Watch Together, relative-seek accumulation and live capture-buffer policy remain in those owners. Closing the native window returns the plane to its pane; explicit full-route restore waits for successful native attachment. Tokens reject delayed controls; at most 32 intents queue. |
| Window geometry | Profile/slot SHA-256 keys separate geometry without storing profile names or media credentials. macOS uses frame autosave and screen clamping. Windows stores validated bounds and clamps restored windows to an available work area. Wayland persists normal window size; global positioning belongs to the compositor. Persistence updates during movement/resize, so a clean close is not required to retain the last saved geometry. |
| Native lifecycle | Native windows belong to their existing native player plugin. Player/profile teardown closes them before destroying native resources. Parent-widget geometry/visibility cannot hide or resize a detached plane; its latest requested visibility is applied when the plane returns, including parked panes. Source playback persists but does not pause when Flutter loses focus to its native video window. A window close does not create another playback owner or end the media session. |
| Other surfaces | Supported desktop non-video surfaces can move into additional Flutter views on the existing engine. Their original routes/services retain ownership; window messages contain opaque tokens and presentation metadata. Native video keeps its platform-specific plane adapter. TV platforms retain their in-app workspace adapters. |
| Games | Android GameStream/Moonlight and Steam expose retained native surfaces with separate audio/input ownership and explicit teardown. Android GameStream keeps the original Activity for full-screen playback and admits one live Moonlight connection at a time because its native bridge is process-wide. Its controller handler and virtual controls exist only while that surface owns input; lease loss releases active inputs and destroys handler state and callbacks before another surface can claim the lease. Surface loss suspends input and starts a bounded recovery window; a recreated valid SurfaceView target is rebound to the active MediaCodec, with a graceful session stop when rebinding fails. The Android release workflow generates, attests and attaches a corresponding-source archive for the locked Moonlight receiver and Pleazyng adapter, including recovery for older reused Android artifacts. Archive generation and release assembly have not yet run on this workflow revision. The Android debug compile passed at `7b35413f1fbedf6cc85f9afb9ff5843c9738b74e`, including Moonlight native builds for arm64-v8a, armeabi-v7a, x86 and x86_64. PlatformView frame latency, surface recovery and physical-device decoder/input/audio behavior still need qualification. |
| Recovery | Profile-local checkpoints retain safe identities, positions and layout. Open **Settings → Manage media sessions** to resume or dismiss a saved session after restart. Resume reauthorizes through the current profile and existing media/source routes. Library video, source audio and readers, including fully cached source editions, use the same owner guards. Checkpoints never store media URLs, credentials, players or provider sessions. Missing workspace checkpointing cannot abort player startup. Games are never launched automatically. |

#### Upstream sources

The Moonlight decoder API used for retained-surface recovery comes from upstream [Moonlight Android commit `b48494cb`](https://github.com/moonlight-stream/moonlight-android/commit/b48494cb96bff23d8886c4775cc4f39a1075495d), authored by [@cgutman](https://github.com/cgutman). Pleazyng independently adapted the decoder lifecycle; see [UPSTREAM_ATTRIBUTION.md](../../../UPSTREAM_ATTRIBUTION.md#credited-moonlight-android-source).

## Validation

Local focused validation passed 155 tests for workspace/recovery, profile
navigation, source playback and signed catalogs, plus 13 player-startup
regressions after optional checkpoint attachment was corrected. The latter
cover live fallback, display matching, retry UI and ambient-light restoration
without a workspace provider. Native-window calls have deadlines, and the
unresponsive-availability regression passed. Native desktop and device results
remain separately recorded in the [audit ledger](../../security/audit-remediation-2026-11-09.md).
The focused workspace-overlay suite also verifies semantic activation of an
interactive game pane and transfer of its input lease.

Required platform acceptance remains: detach/reattach each admitted video slot,
resize and move between mixed-DPI/HDR displays, unplug the saved display, exercise
native keyboard/screen-reader controls, close while paused/buffering/seeking,
change profiles during pending commands, and confirm uninterrupted progress with
one audible owner. Linux must also cover in-flight render/HDR transactions and
compositor-driven resize/placement. Release claims require these results at the
packaged source revision.

The Multiview audio-control source change has not been physically qualified on
any platform. In particular, the MPV desktop capability check proves only that
the active source reports decoded audio, `audio-exclusive=no` and a matching
`audio-device` property; it does not prove acoustic output, drift behavior,
route-change handling, focus behavior or packaged-device compatibility.

Wayland reparenting follows the core protocol's rule allowing another
`wl_subsurface` for the same `wl_surface` after its old subsurface object is
destroyed: https://wayland.freedesktop.org/docs/html/apa.html .
