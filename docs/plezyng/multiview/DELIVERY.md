# Multiview delivery ledger

Current source: main, assessed and remediated on 2026-11-05. Earlier draft-branch
instructions and completion claims in this file have been superseded by the
owner's direct-to-main remediation request. This ledger distinguishes source
implementation from executed platform qualification.

| Area | Current implementation |
| --- | --- |
| Workspace | Profile-scoped live adapters, floating/split/fullscreen layouts, placement history, restore/park/tray actions, one selected audible owner and exclusive gamepad-input leases. Existing routes/services own auth, progress, players and teardown. |
| Video admission | Primary/companion native player slots are reserved before asynchronous teardown and retained through native disposal. Workspace admission caps video at two sessions. |
| Detached desktop video | macOS lends the retained AVFoundation video and OSD layers to a public AppKit window. Windows reparents the retained mpv video HWND. Linux/Wayland recreates only the existing producer surface's subsurface relationship; render context, decoder and colour objects remain owned. Presents/HDR transactions must drain before reparenting. No media URL or credential is copied to argv, disk or another process. |
| Detached controls | Localized native buttons delegate play/pause and skip intent to the original video/source route. Watch Together, relative-seek accumulation and live capture-buffer policy remain in those owners. Closing the native window returns the plane to its pane; explicit full-route restore waits for successful native attachment. Tokens reject delayed controls; at most 32 intents queue. |
| Window geometry | Profile/slot SHA-256 keys separate geometry without storing profile names or media credentials. macOS uses frame autosave and screen clamping. Windows stores validated bounds and clamps restored windows to an available work area. Wayland persists normal window size; global positioning belongs to the compositor. Persistence updates during movement/resize, so a clean close is not required to retain the last saved geometry. |
| Native lifecycle | Native windows belong to their existing native player plugin. Player/profile teardown closes them before destroying native resources. Parent-widget geometry/visibility cannot hide or resize a detached plane. A window close does not create another playback owner or end the media session. |
| Other surfaces | Music, publication readers, Steam/game surfaces and native TV video keep their current in-app workspace adapters. They do not advertise desktop video-plane detachment. |
| Recovery | The existing profile-local workspace snapshot retains safe descriptors, placements and ownership preferences. On application restart, live media owners are supplied by normal routes/services; snapshots never deserialize credentials, players or provider sessions. Automatic playback restart following an application crash is not implemented by the window host. |

## Validation

The relative Dart directive/import check passes against the complete tracked-path
inventory. New Flutter regression cases cover token rejection, control revocation
on native close, geometry isolation and awaiting attachment before route restore.
Those cases are authored, not executed: Flutter/Dart and the desktop platform SDKs
are absent in this environment. Native compilation and device results are unknown.

Required platform acceptance remains: detach/reattach both reserved video slots,
resize and move between mixed-DPI/HDR displays, unplug the saved display, exercise
native keyboard/screen-reader controls, close while paused/buffering/seeking,
change profiles during pending commands, and confirm uninterrupted progress with
one audible owner. Linux must also cover in-flight render/HDR transactions and
compositor-driven resize/placement. Release claims require these results at the
packaged source revision.

Wayland reparenting follows the core protocol's rule allowing another
`wl_subsurface` for the same `wl_surface` after its old subsurface object is
destroyed: https://wayland.freedesktop.org/docs/html/apa.html .
