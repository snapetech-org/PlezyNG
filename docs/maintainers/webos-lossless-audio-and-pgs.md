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

### Controlled C6 native-decoder trial

The owner subsequently authorized physical playback testing. The pinned DTS
decoder and switching bin were staged without running the upstream installer.
The live Plex session then direct-played the original HEVC and DTS-HD MA
six-channel streams, with no server conversion. LG reported active raw audio
from the media pipeline, and the owner reported hearing sound. The receiver's
input format and channel count remain unverified. This trial does not establish
DTS-HD bitstream passthrough: it currently uses the software decoder.

The trial changes are persistent and currently active:

- Owned directory: `/var/lib/webosbrew/dts25`, marked by `pleazyng-owned` with
  the exact value `pleazyng-c6-test-20261108`.
- Files: `libgstdtsdec.so`, `libgstadecswitch.so`, `lgroute-control`, and the
  original registry backup `original-registry.bin` (mode 0600).
- Source: DTS Restore Plus commit `2cbf121509fdf93159b0f9ca756235eec39ccaba`;
  source archive SHA-256
  `259622906e6b7f45ec34e661a1f5f011a00ff158112c9ed2cfabf0a8ad2d9228`.
- Decoder SHA-256:
  `fc9319aa80153aef1a324487a71964f9a5ad3c7db95bc1320ba5bdd8fa0903bb`.
- Live registry: `/mnt/flash/data/gst_1_0_registry.arm.bin`, SHA-256
  `97535f49bce49f42e93c295dbe6fb698b69a1609ac7776cfcbeba5ded28cba55`.
- Original registry SHA-256:
  `ab0d3959eb6f53831d5ed28125c979bba2d79e46a4f4c0e3199810c85c2529fd`.

The replacement registry was scanned into task scratch with the stock plugin
directories plus the owned directory, then activated after verifying the
switching bin selected the staged decoder. No stock library was replaced, no
boot hook or config bind was installed, no passthrough marker/watch process was
enabled, and no gain/DRC or sound-output setting was changed. Digital output
remains `auto`, with external ARC and eARC enabled. No global media service was
restarted. Do not run the upstream installer over this trial: its defaults and
service restarts are different.

Preserve these files while the live registry or a pipeline uses them. To undo
the trial, first verify ownership, the original backup hash and that the live
hash still matches this receipt. Restore the backup's contents to the live
registry; if another writer changed it, investigate instead of overwriting it.
Wait for consuming media pipelines to exit before removing only owned files.
Never kill all `starfish-media-pipeline` processes: other apps and inputs share
them. The installation remains a controlled trial, separate from the immutable
3.0.4 app package and the forthcoming managed runtime/settings integration.

Private receipts: `c6-controlled-trial-state.json`,
`plex-playing-trial-private.json`, `c6-active-decoded-audio-burst-private.json`
and `c6-active-pcm-graph-private.txt` in the implementation evidence directory.

### Playback diagnostics

The native adapter now forwards source audio codec, channels, bitrate and sample
rate, plus source video codec, frame rate and bitrate. LG's audio sample-rate
field is in kHz and is normalized to Hz. Native `audioInfo.track` events identify
the active track, including the initial selection. The performance overlay can
therefore display these fields, and the playback header shows the active audio
format/channel layout. Native source summaries also go to the existing
`video_player_drm` system-log context without media URLs or credentials.

Native TV startup additionally attaches `pleazyng-diagnostics.log` in the
app's application-support directory. On the current C6 this is under
`appdata/.data/org.snapetech.pleazyng/`. Its records pass through the same
redaction as the in-app log, including error and stack fields. Active native
audio changes are logged once per format/track change. Each log is capped at
2 MiB with one previous file; pending writes are capped at 64 KiB. Disk refusal
disables that writer without blocking startup or playback. Inspect it over SSH
without launching or foregrounding the app. Do not enable global vendor debug
collection to compensate for missing application diagnostics.

These are source/decoder diagnostics, not receiver telemetry. The adapter
deliberately leaves output channels and passthrough status unknown when LG does
not report them; never infer them from the source or the ARC carrier's channel
count. The HDR badge emitted by the TV is independent of the app's controls.

### 3.0.5 controlled test and remaining reporting gaps

Candidate `b674649391da0055dfddb8da75a44dcfe1b3d269`, IPK SHA-256
`90be03d9877e7e10541d62c590047050fb74139670d77925f2bbe76acae7c21d`,
installed successfully; all five checked installed binary hashes matched the
package. The owner confirmed home artwork/previews returned and sound was good.
The captured Plex session identified Pleazyng 3.0.5 with original HEVC and
DTS-HD MA six-channel audio and no transcode session. No image-load failure was
captured. The owner returned to HDMI 2 after that single authorized window;
do not foreground the TV again without another window.

The new private log also exposed LG returning codec `unknown` with no channel,
sample-rate or bitrate values for the working DTS path. Forwarding fields
cannot supply information absent from the driver. The app now retains backend
audio profile/rate/bitrate metadata and offers it as a source-track fallback
only for an unchanged original rendition and a complete matching track catalog.
Native known formats win. Converted renditions, incomplete catalogs and later
opens without new hints never inherit original-file labels. Logs explicitly
identify `origin=server-source` versus `native-source`, retain the raw native
values/catalog counts and keep receiver output unreported. This identifies the
source being played; it does not qualify decoding depth or eARC transport.

The same capture contained repeated `os_media_controls` MissingPlugin warnings.
That desktop/mobile plugin has no webOS/Tizen backend. Its integration now
avoids plugin calls, artwork fetches, event subscriptions and update timers on
those native TV platforms; native-player and app input handling remain active.
The controlled capture is in `test-window-305/` under implementation evidence.

### Home artwork recovery

The owner clarified that the missing previews are home/library pictures. The
Odyssey's absent BIF index (HTTP 404) is a separate seek-preview limitation.
Read-only probes returned valid JPEG artwork for the home titles inspected;
that alone does not establish which requests failed on the device.

The app had independently reproducible recovery defects: cards read their
server client without subscribing to reconnects, a missing owner could resolve
relative image IDs against an unrelated server, wide cards disabled fallback
images, and failed hero paths survived an endpoint change. Cards and heroes
now observe their own source client, hero failure state resets when the source
URL changes, and wide cards try available alternate artwork. Failure memory is
keyed by resolved URL and expires after two minutes instead of poisoning the
same relative path across servers for the process lifetime. Regression checks
cover client arrival, in-place endpoint changes, fallback selection and expiry.
Physical verification of this package remains a separate controlled test.

### Match the release compiler during preflight

`tools/webos/check_audio_plugin_syntax.sh` now uses the pinned NDK Clang ARM
frontend, sysroot and strict release warning policy. The SDK environment's
`CXX` names GCC, while Flutter-webOS's CMake builder selects Clang explicitly.
GCC accepted an anonymous typedef containing default member initializers that
Clang rejects under `-Werror`; use a named C++ struct for that metadata type.
All audio/video plugin translation units pass the corrected Clang preflight.

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

## RX500A receiver diagnostics without a TV OSD

The owner-tested 3.0.5 candidate at `fcb2541de` reports original-source
DTS-HD MA, six channels, 48 kHz and 3,876,000 bps in its persistent log,
explicitly marked `origin=server-source`. The owner confirmed that the
performance overlay displayed the video/audio codecs and six audio channels.
These fields describe the file; they do not measure the Yamaha's input.

The RX500A uses Yamaha's [Audio Connect](https://usa.yamaha.com/products/audio_visual/apps/audio-connect/index.html),
with a StreamSDK node API. The older `YamahaExtendedControl` and
`YamahaRemoteControl/ctrl` endpoints returned HTTP 404 on the inspected receiver.
After finding its current LAN address, these bounded requests read identity,
the reported input and player data without changing volume, inputs or settings:

```sh
curl --noproxy '*' --fail --silent --show-error --max-time 3 --max-filesize 65536 \
  --get "http://$RECEIVER_HOST/api/getData" \
  --data-urlencode 'path=settings:/deviceName' --data-urlencode 'roles=value'
curl --noproxy '*' --fail --silent --show-error --max-time 3 --max-filesize 65536 \
  --get "http://$RECEIVER_HOST/api/getData" \
  --data-urlencode 'path=settings:/yamaha/audioInput_rx500a' --data-urlencode 'roles=value'
curl --noproxy '*' --fail --silent --show-error --max-time 3 --max-filesize 65536 \
  --get "http://$RECEIVER_HOST/api/getData" \
  --data-urlencode 'path=player:player/data' --data-urlencode 'roles=value'
```

With the receiver on the PC's HDMI 1 input, the input node reported `hdmi1`
and the network player reported `stopped`. Neither observation tests eARC.
The first passive capture missed the short app window because it required the
receiver input node to change first. Trigger captures from a new app-owned
`webOS active audio metadata` diagnostic event; seed the previous event before
waiting so an old paused stream cannot trigger a new qualification. Retain
`com.webos.surfacemanager/getForegroundAppInfo` and the raw receiver input
alongside each sample. Correlate source, route and sample times; do not treat
a streaming-player state as an HDMI/eARC format unless an active TV-input
sample establishes that relationship.

Read-only LG evidence includes `com.webos.service.arccontroller/getARCState`,
`com.webos.service.audio/tv/getAudioInputProperty`,
`com.webos.service.audio/getStreamStatus`,
`com.webos.service.audio/UMI/getStatus`, and
`com.webos.service.audiooutput/audio/getStatus`. On this C6, `getARCState`
reports an eARC connection and advertised maxima of eight PCM, DTS-HD MA and
TrueHD channels, plus six DTS channels. These are receiver capabilities.
They are not the current program's received format or channel count.

For a rooted-TV output snapshot, enumerate the current instance directories
below `/proc/aaudio/processors/dsp1/{output_arc,enc_mat,encoderbin,outctrlbin}`
and read only their `status` and `prop` files. Do not hardcode instance IDs,
write driver controls or restart services. In particular, `output_arc`'s
two carrier slots are not evidence of stereo decoded audio. Preserve the
separation between source metadata, decoder/output diagnostics and measured
receiver input. An actual RX500A eARC codec/channel readout remains unverified.
