# Remaining TV host integration

Status: source/API investigation, **no implemented TV MilkRust host**. The app's
ordinary LG/Samsung media playback is separate from the mpv audio core used by
the Linux/Windows/Apple/Android visualizer hosts. Audio metadata and a texture
registration API alone do not supply the decoded samples for this feature.

## Tizen

The vendored Samsung plugin owns `player_h` in
`packages/tizen_plugins/video_player_videohole/tizen/src/media_player.cc`.
`MediaPlayer::Create` currently sets a display for every player. PlezyNG's
`PlayerTizen.audioOnly` flag currently controls the Dart video surface, not a
native audio-only/PCM mode. The network controller forwards `playerOptions`,
but the file-controller constructor/create route does not currently forward
an equivalent option.

Samsung documents `player_set_media_packet_audio_frame_decoded_cb` for decoded
PCM, configured before prepare. The default extraction option synchronizes to
the playback clock; callback packets must be destroyed promptly. Audio offload
and codec/device capability can make extraction unavailable. The .NET wrapper's
documented export path also requires no display. These are candidate APIs,
not evidence that the TV SDK/firmware used by this app exposes the same contract.

The [Flutter Tizen embedder at 85eec293](https://github.com/flutter-tizen/embedder/tree/85eec293413fdc25dd720f634a402f8da5c7b0f9)
does expose pixel-buffer textures, release callbacks and asynchronous texture
unregistration. The actual pinned SDK revision still needs to be checked when
building the host. It is not sufficient to copy a Windows texture class and
declare the TV complete.

Implementation must connect all of the following in the existing player:

1. Carry an explicit audio-only request through network and local-file creation,
   keep video-plane setup off that path, and negotiate the real TV PCM API before
   prepare. Unsupported extraction must preserve ordinary audio playback.
2. Copy bounded PCM packets into a native queue and release vendor packets in
   the callback. Never fetch player properties synchronously from the render
   thread. Preserve timestamps and reset generations on seek/source/track changes.
3. Own MilkRust's EGL context on its worker, bound texture decoding before
   allocation, publish independently leased pixel buffers, and unregister the
   texture before freeing its callback state. Do not terminate Flutter's shared
   EGL display when disposing a visualization context.
4. Bind the visualization lease to the exact opaque Samsung player ID and stop
   the worker before source/player disposal. Exercise callback-drain, pause,
   buffering, seek, suspend/resume and output-route behavior on a physical TV.
5. Package the reviewed 32-bit ARM renderer and corresponding source/notices.
   The existing x64 Tizen emulator package is not physical-TV qualification.

Primary references: [Samsung player API](https://docs.stg.tizen.org/application/native/api/mobile/6.0/group__CAPI__MEDIA__PLAYER__MODULE.html),
[Samsung Player wrapper](https://samsung.github.io/TizenFX/stable/api/Tizen.Multimedia.Player.html).
The former is a mobile API reference; TV availability must not be inferred from it.

## webOS

`packages/webos_plugins/video_player_drm/webos/webos_player.cc` delegates media
to LG's pipeline. Its integrated callback interface exposes playback, timing,
track, buffering and DRM events, not decoded PCM. The `PlayerWebOS.audioOnly`
flag likewise hides the Dart video surface; it does not replace the decoder.
The current release packaging targets `webos/arm`, not arm64.

An approved PCM callback from that exact playback pipeline, or an explicitly
implemented audio-only backend that owns both decode and audible output, is
required before a MilkRust host can attach. A second muted decoder, microphone
capture, system-wide capture, fabricated FFT or loopback HTTP proxy is not an
implementation of the planned same-player tap. No public PCM contract was
identified in the integrated plugin during this inspection; that does not prove
LG cannot provide a supported partner API. The platform texture/context bridge
and lifecycle work still follow after a real PCM source is established.

## Qualification

Both TV targets remain open in the original completion plan and in
`all-native-hosts-v1`. No callback was installed, no TV package was built, and no
device or render evidence was produced in this source-only increment. A broader
pack cannot be promoted through the new publisher gate while those evidence
cells remain missing. The source-only restriction must be lifted for approved
private JIT/device execution; it does not itself resolve these code/API gaps.
