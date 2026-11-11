# Playback compositor behavior

Apple MPV playback supports GLSL presets and ambient lighting through
AVFoundation's libplacebo/MoltenVK stage. Presets use the display size; ambient
lighting stretches the shader output across the layer while preserving the
picture aspect used to place subtitles. Existing Settings controls select
these features. Android ExoPlayer keeps its separate Lanczos resampler.

The Apple stage skips Dolby Vision, Core Image zoom/pan, composited subtitle
frames and background iOS/tvOS playback, with the reason logged. The original
frame continues through AVFoundation. Heavy presets still depend on GPU
capacity; simulator checks do not qualify physical-device performance.

Android MPV uses transparent letterbox margins on Amlogic devices that report
their SoC vendor, excluding Amazon devices. This follows upstream reports
that opaque graphics-plane black is raised during Dolby Vision output on
these devices. Other devices retain opaque black.

Amlogic and MediaTek TV devices receive a one-refresh subtitle-plane delay.
The native scheduler presents unchanged subtitles on every video frame,
preventing the delay from disturbing video cadence. Phones, other SoCs and
devices without a reported vendor keep zero delay.

These changes preserve the bundled FEL and neural paths and their persisted
Settings choices. Native package qualification does not establish the physical display's black level or scanout
timing; those observations require the affected hardware.

## Late-mounted video surfaces

Open Media, source workspaces and karaoke can begin playback before mounting
`Video`. A broadcast playback-restart event may already have fired by then.
Without an external loading gate, `Video` reads the current player's persisted
`hasRenderedFrame` state at mount, player replacement and notifier rebinding.
Queued restart events read the current snapshot, so an old load's event cannot
reveal a newer load before it renders. An explicit first-frame notifier retains
control while the main player negotiates its display mode. This is shared Dart
behavior rather than a platform-specific rendering workaround.

Native qualification must exercise both the standard server player and Open
Media. Record moving video, elapsed time and audio before seeking, changing
fullscreen mode or reattaching the view: those actions can emit another restart
and hide a missed initial event. Widget pixel tests cover late mounting,
replacement, stale events and explicit holds across Linux, Windows, Apple MPV
and Android ExoPlayer; they do not establish physical-device output quality.

## Upstream sources

The records below informed the shader and TV behavior above. The late-mount
frame binding was independently developed from Pleazyng's regression tests and
native playback observations.

[@edde746](https://github.com/edde746) contributed the
[Amlogic letterbox correction](https://github.com/edde746/plezy/commit/63f8cd5a054e2ecc5c28dd30fe8066f4356a10c4),
[Apple shader controls](https://github.com/edde746/plezy/commit/2e1654b316150f59cbc4774602ed4f02a3515527)
and [TV subtitle offset](https://github.com/edde746/plezy/commit/6cc283a7da3d75ed90ec232dd7f5da1f25681b4f)
to upstream Plezy. Pleazyng independently adapted these changes and integrated
their corresponding native implementations with its playback engine. This
does not imply contribution to or endorsement of this fork. The associated
native [shader stage](https://github.com/edde746/mpv-build/commit/2b23527),
[stretch fix](https://github.com/edde746/mpv-build/commit/9929c5e),
[letterbox control](https://github.com/edde746/mpv-build/commit/bc87af7),
[early queue](https://github.com/edde746/mpv-build/commit/98452a9) and
[per-frame repetition](https://github.com/edde746/mpv-build/commit/8958474) were
also contributed by that author upstream and independently integrated here. See
[the attribution ledger](../../UPSTREAM_ATTRIBUTION.md).
