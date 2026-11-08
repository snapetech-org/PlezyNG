# C6 lossless audio and client-rendered PGS

Research and read-only device inspection: 2026-11-08. Target:
`OLED77C6HUP.ACCQLJD`, firmware `43.21.79`, webOS `11.2.0` / webOS 26.
The initial findings describe released 3.0.4. Implementation progress below
separates new headless validation from physical receiver qualification.

## Findings

| Question | Finding | Confidence |
| --- | --- | --- |
| Can eARC transport DTS-HD MA / TrueHD? | Yes; both formats are within the transport's capabilities. | High |
| Can the Yamaha RX500A decode them? | Yes; Yamaha lists both formats. | High |
| Does that make the C6 native app accept them? | No. Receiver and transport support do not supply a missing TV demux/decoder/output route. The observed native DTS path omitted all source audio tracks. | High |
| Is lossless output categorically impossible on this rooted TV? | Not established. A current homebrew implementation demonstrates experimental HD passthrough on other LG hardware; this C6 has a different, unqualified sink build. | Unknown for this C6 |
| Must PGS always require video encoding? | No. A client can decode and overlay the subtitle bitmaps while leaving the video unchanged. The new webOS implementation handles local/HTTP SUP; embedded-container delivery is still being implemented. | High |

Primary references:

- [HDMI Licensing Administrator: eARC formats](https://www.hdmi.org/spec21sub/enhancedaudioreturnchannel).
- [Yamaha RX500A specifications](https://usa.yamaha.com/products/audio_visual/av_receivers_amps/rx500a/specs.html).
- [LG OLED77C6HUP specifications](https://www.lg.com/us/tvs/lg-oled77c6hup-oled-4k-tv).
- [LG webOS 26 AV specification](https://webostv.developer.lge.com/develop/specifications/video-audio-260): DTS-family support is model-dependent; WebVTT is the listed web subtitle format. This generic table does not establish the native NDL backend's capabilities on every model.

## Why audio currently converts

The released app attempts the original audio first. The earlier native trace
for the Odyssey source reported one video track and zero audio tracks despite
four DTS source tracks. The bounded compatibility retry therefore asks Plex
for supported audio. The subsequently inspected production session delivered
six-channel AAC at 768 kbps, with PGS burned into re-encoded video. Six channels
in the delivered stream do not prove six channels at the receiver.

Read-only settings inspection found external ARC selected, eARC enabled and
Digital Sound Output `auto`. An enabled eARC setting alone does not prove an
active HD bitstream route. HDMI-input passthrough and media originating in a
native TV app are separate paths; do not use one as qualification for the other.

Relevant app implementation:

- `lib/media/webos_playback_profile.dart`: permitted fallback formats and explicit
  audio-rejection classification.
- `lib/mpv/player/platform/player_webos.dart`: LG native playback and audio-track
  discovery.
- `lib/screens/video_player/parts/errors.dart`: bounded compatibility recovery.
- `lib/services/plex_client.dart`: audio conversion and subtitle burn decisions.

### Rooted-TV route worth investigating

The current [DTS Restore Plus passthrough investigation](https://github.com/josippapez/dts_restore_plus/blob/2cbf121509fdf93159b0f9ca756235eec39ccaba/webos25/docs/PASSTHROUGH.md)
reports receiver-confirmed experimental DTS-HD and TrueHD on a C2, distinct
from DTS-core fallback and software decoding. Its newer introduction supersedes
older text saying bitstream passthrough is impossible. HD transport uses an
IEC 61937 carrier and LG-managed unmixed eARC routing; it requires Pass Through
and verifies the sink build. A DTS-core success is not DTS-HD MA qualification.

The pinned upstream app source also records a receiver-confirmed G2 sink build:
[sink allowlist and watcher](https://github.com/josippapez/dts_restore_plus/blob/2cbf121509fdf93159b0f9ca756235eec39ccaba/webos25/app/service/service.js#L973).
Neither supported sink SHA-256 matches the C6 inspected here:

```text
C6 libgstlgaudiosink.so SHA-256:
883093db3a2b9b518ddf37231eaebb7b62723737dc9417510f091a929906bde5

Upstream allowed sink SHA-256 values at 2cbf121509fdf93159b0f9ca756235eec39ccaba:
90dba3ef32704ce4096bf1e6045d2879d0c2192d507bc04d1e8e98437f420a43
792caa7e048a8550ec3c67e0fd4c9d94684d0633e0ff250a2bcbd0e29d538fe9
```

The C6's stock `libgstlibav.so`, `libgstisomp4.so` and
`libgstmpegtsdemux.so` MD5 tuple is also absent from the upstream documented
supported-build table:

```text
6f65d9b227544502e89031d3f1fc7288
24a41b3fb814b8df8d87b4748d57541d
4c0ba70033691ff1c665f8c8356fd46f
```

The C6's `/proc/aaudio/processors/dsp0` lists no `dec_dts` module. Its generic
`/etc/umediaserver/device_codec_capability_config.json` nevertheless advertises
DTS-family entries, and `/etc/gst/gstcool.conf` contains a DTS decoder rank.
Those configuration entries alone therefore cannot prove working playback.
The absent decoder does not establish that an independent bitstream route is
impossible. The generic PCM/LPCM entries advertise two channels; software
decoding to multichannel PCM must also be qualified through the real output
stage rather than assumed to preserve surround over eARC.

No homebrew overrides, output-setting changes, plugin loading, playback launch
or service restarts were performed for this research. An implementation needs
a C6-specific compatibility assessment, integration with the app's native video
pipeline, and a controlled receiver test. Preserve the working fallback.
Receiver confirmation must distinguish DTS core, DTS-HD MA, TrueHD and PCM,
and record input channels rather than an upmix/sound-program label.

## PGS without video transcoding

The released 3.0.4 webOS `videoSurface()` layers Flutter text captions over
LG video. Its external-caption reader accepts local SRT/WebVTT only. During Plex audio conversion, embedded selected
subtitles are requested as `subtitles=burn`; adding a codec name to the server
profile without a working delivery/renderer path would lose captions.

[libbitsub](https://github.com/altqx/libbitsub) is an MIT-licensed PGS/VobSub/DVB
parser and renderer. Its [pure Rust core](https://github.com/altqx/libbitsub/blob/main/crates/core/Cargo.toml)
is separate from its browser/WASM wrapper. A native ARMv7 FFI adapter or an
app-owned Dart decoder is a fit for this Flutter application; the JavaScript
canvas integration is not directly usable by our native backend. Jellyfin's
[player implementation](https://github.com/jellyfin/jellyfin-web/blob/master/src/plugins/htmlVideoPlayer/plugin.js)
provides another primary example of client bitmap-subtitle handling.

Delivery is a separate part of the feature. On the actual Plex server, the
selected embedded PGS track has no sidecar `key`. All three bounded GET probes
returned HTTP 501, with no PGS bytes:

```text
/library/streams/{stream_id}
/library/streams/{stream_id}.sup
/library/streams/{stream_id}?format=sup
```

Consequently a complete implementation needs:

1. A subtitle delivery route: standalone SUP when available, optional
   subtitle-only server extraction, or selected-track demux from the original
   container. Do not assume Plex can hand out embedded PGS through the sidecar
   endpoint. Avoid a second full movie download or blocking startup on a whole
   file scan; range seeking, bounded buffering and cancellation matter.
2. A bounded PGS decoder retaining palettes, transparency, multiple objects,
   cropping, positioning, forced flags and composition/clear events.
3. A Flutter bitmap overlay synchronized to the player's media clock, including
   seeks, resume offsets, pause, subtitle delay, aspect ratio and letterboxing.
4. Plex decision changes that suppress burn-in only after local delivery and
   rendering are available. Keep audio-only conversion independent of captions,
   honor explicit subtitle selections, and retain an accurate failure fallback.
5. Real PGS fixture checks and headless rendering, followed by a controlled C6
   playback with Plex reporting video copy and visible correctly timed captions.

This avoids subtitle-driven video encoding without OCR or replacing the
selected track with different text. Audio compatibility may still require a
separate conversion until the lossless output route works.

### Implementation progress

`lib/media/pgs_subtitles.dart` now parses bounded SUP display sets, reassembles
fragmented objects, retains palette updates, validates RLE without allocating
full frames, and rasterizes only the active cue. The webOS player supports
local and bounded authenticated HTTP SUP delivery, delayed/hidden/off
subtitles and asynchronous selection cancellation. The Flutter image overlay
uses premultiplied alpha and scales the authored canvas with letterboxing.
Embedded Matroska extraction and Plex no-burn negotiation remain separate work;
do not claim embedded PGS support from the SUP renderer alone.

Headless validation passed 12 parser cases, 14 native-backend cases and a real
Flutter pixel-rendering case. A private 180-second sample of the selected
Odyssey PGS stream parsed 86 display sets and rasterized 43 images covering
1,435,991 pixels. These are parser/rendering results, not a visible C6 test.

An isolated C6 GStreamer process also loaded the pinned upstream DTS decoder
and produced S32LE, 48 kHz, six-channel PCM without an audio/video output sink.
The C6 output contained 4,230,456 bytes; after compensating 1,907 samples of TS
start clipping, every byte matched the desktop FFmpeg reference. Automatic
decoder selection through the upstream switching bin also succeeded. This
qualifies software decoding for that sample, not HDMI/eARC receiver output.
No system-wide plugin/configuration changes were made by these tests.

Implementation evidence is under
`/mnt/disks/scratch/task-scratch/pleazyng-c6-lossless-pgs-20261108/`.

## Reproducible evidence

Private task evidence is retained under
`/mnt/disks/scratch/task-scratch/pleazyng-304-playback-20261107/c6-lossless-pgs-20261108/`.
It includes read-only C6 configuration and plugin hashes and the sanitized
Plex subtitle delivery probe. No credentials or movie paths are in this document.

For later firmware comparisons, read the existing device identity and these
paths over the established root SSH connection without loading plugins:

```sh
cat /etc/os-release
cat /etc/umediaserver/device_codec_capability_config.json
cat /etc/gst/gstcool.conf
sha256sum /usr/lib/gstreamer-1.0/libgstlgaudiosink.so
md5sum /usr/lib/gstreamer-1.0/libgstlibav.so /usr/lib/gstreamer-1.0/libgstisomp4.so /usr/lib/gstreamer-1.0/libgstmpegtsdemux.so
ls /proc/aaudio/processors/dsp0
```

Use `tools/webos/luna_ssh.py` for read-only settings/status calls as described
in [the TV runbook](webos-tv.md#released-304-audio-inspection). Do not restart
or foreground the app while the owner is watching another source. Firmware
hash equality, a decoded multichannel buffer, or a server copy decision alone
does not qualify the physical receiver output.
