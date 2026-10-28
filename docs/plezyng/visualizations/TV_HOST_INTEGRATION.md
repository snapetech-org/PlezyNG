# TV visualization integration

Status: Tizen PCM, EGL/texture host and optional artifact packaging source from
closed [PR #74](https://github.com/snapetech-org/PlezyNG/pull/74) were merged
through [PR #78](https://github.com/snapetech-org/PlezyNG/pull/78). Those
sources have not been compiled or run. webOS now has a separate, bounded
SoLoud-owned audio route and native PCM/texture host source; the standard
candidate-build source path builds and requires its MilkRust runtime bundle.
Neither platform is release-qualified.

## Tizen source implementation

The existing Samsung `MediaPlayer` remains the sole decoder and audible output.
`PlayerTizen.audioOnly` now reaches both network and local-file creation. The
player hides its display during creation and requests native audio-only mode
after prepare; that setter requires READY/PLAYING/PAUSED, not IDLE. Failure to
negotiate visualization PCM does not prevent ordinary music playback.

Before prepare, the host negotiates stereo signed 16-bit little-endian PCM at
44.1 kHz with `player_set_media_packet_audio_frame_decoded_cb` and the playback-
clock-synchronized `PLAYER_AUDIO_EXTRACT_DEFAULT` option. The optional symbols
are discovered at runtime. Protected media and incompatible codec/offload
routes remain unavailable; the integration does not change output routing.
Non-normal playback speed is also explicitly unavailable in this version.

The PCM queue owns 16 slots of at most 512 frames. It validates the packet format,
size and nanosecond PTS, copies a bounded tail, and destroys the vendor packet
in the callback. The callback never enters Dart, GL or filesystem code. It drops
analysis rather than waiting for the renderer's queue lock. Copying is disabled
while no visible renderer is consuming audio. Pause, seek, track/rate changes
and suspend reset generations. Pending blocks are paced and expire after
200 ms; generation checks also reject stale rendered frames after rebinding.

Callback registration uses a non-reused integer token rather than a pointer to
`MediaPlayer`. The teardown path closes the queue, requests unregister after
stop, and drains callbacks/packet destruction before unprepare. The precise
firmware callback/unregister contract, including failure and late-callback
behavior, still requires physical-device qualification.

Dart binds the host to the exact opaque Samsung music-player ID. Unbinding an
older ID cannot detach a newer source. The app's native-audio capability now
admits this bound player as well as mpv. Visualization method failures are
separate from ordinary playback errors. A source switch reuses the selected
preset/texture session while the new PCM generation resets engine feedback.

`visualizer_host.cc` implements the existing native control channel, one leased
MilkRust session, a worker-owned GLES 3 pbuffer context and Flutter pixel-buffer
textures. Rendering is bounded to 1280×720 at approximately 30 FPS. Each frame
has an immutable pixel lease; at most four leases may be outstanding. The
worker stops publishing before asynchronous texture unregistration releases
callback state. Context cleanup never terminates Flutter's shared EGL display.
A driver/compiler hang is still uncontained by the shared in-process worker;
context-loss recovery and bounded teardown remain release gates.

Texture input uses pinned MIT `stb_image` with PNG/JPEG/BMP/TGA enabled. Encoded
input is capped at 16 MiB, dimensions at 4096 per side and 8 MiPixels, and decoder
scratch at 96 MiB. DDS and other image formats are explicitly unsupported here.
No decoder fuzzing or visual comparison has run. The MIT notices are included
in the app's license registry and corresponding source.

## Tizen artifact packaging

`scripts/tizen/package.py build` accepts an optional `--visualizer-native`
directory together with `--visualizer-manifest-sha256`. There is no default
renderer download or implicit library discovery. The directory must contain:

- `libmilkrust_native.so` for the selected TV ARM or emulator x64 target.
- `milkrust-source.tar.gz` with its exact corresponding source.
- `MILKRUST-NOTICES.txt` with dependency notices.
- `milkrust-native.json` with `schemaVersion: 1`, `abi: 1`, `sourceRevision`
  matching `native/visualizer/sources.lock.json`, `target: tizen-arm` or
  `tizen-x64`, `librarySha256`, `sourceArchiveSha256`, `noticesSha256`,
  `runnerPolicy: private-ephemeral-jit`, and the reviewed MilkRust Actions
  `buildRun` URL.

The manifest digest must come from independent artifact review. Staging checks
all file digests, bounds and ELF architecture before copying. The package
inspector rejects partial bundles, duplicate runtime locations and changed
payloads. Source and notices accompany the runtime inside the TPK. These are
integrity checks, not cryptographic build attestation or proof that the declared
runner actually built the library. Device qualification remains false in the
report. No native artifact was built, staged, signed or published in this turn.

## API evidence and correction

The earlier investigation incorrectly attributed a no-display restriction to
audio export. Samsung's restriction applies to **video** frame export. The
audio callback requires registration before prepare and prompt packet release.
The source implementation follows the separately documented audio contract.

Primary references:

- [Samsung player API](https://docs.stg.tizen.org/application/native/api/mobile/6.0/group__CAPI__MEDIA__PLAYER__MODULE.html).
- [Samsung media packet API](https://docs.stg.tizen.org/application/native/api/mobile/6.0/group__CAPI__MEDIA__TOOL__MODULE.html).
- [TizenFX source at 4825ac73](https://github.com/Samsung/TizenFX/tree/4825ac73ac761bd2b6cad1382ad189a5b5822094/src/Tizen.Multimedia.MediaPlayer).
- [Flutter Tizen embedder at 85eec293](https://github.com/flutter-tizen/embedder/tree/85eec293413fdc25dd720f634a402f8da5c7b0f9).

The API pages are mobile references, not proof of TV SDK/firmware availability.
The actual pinned build SDK must compile and exercise the host on physical TVs.

## webOS

The existing `PlayerWebOS` video path and its audio-only NDL mode remain
unchanged for video, live streams and unsupported sources. That integrated LG
player still exposes no decoded PCM callback, and the public NDL DirectMedia
feed API consumes app-supplied buffers rather than tapping `NDL_Media`.

A separately owned audio route is now implemented in source for a constrained
subset of music files. Plezy's `Player.audio()` uses LG's pinned
`audioplayers_soloud` plugin only when an authenticated metadata probe confirms
a supported static/progressive MP3, WAV, OGG Vorbis or FLAC file with a known
size of at most 10 MiB. The SoLoud decoder and ALSA output own playback for that
source. Its modified mixer exposes the final interleaved float output to a
bounded single-producer/single-consumer PCM ring immediately before ALSA's
integer conversion. The app binds that output to its music source lifecycle;
pause, seek, source changes and visualizer visibility advance or disable the
PCM generation. Larger files, unknown sizes, live input, HLS, unsupported codecs
and video continue through LG NDL and do not advertise native MilkRust audio.
SoLoud errors retry through the NDL route.

The native plugin also owns a GLES 3 pbuffer context and Flutter pixel-buffer
texture, with a worker-owned MilkRust renderer, bounded image decoding and
leased pixels. The host is registered by the app's webOS Flutter plugin
registrant. The release-candidate source path now cross-builds the exact pinned
MilkRust crate, bundles its corresponding-source archive and notices, and
requires the runtime in every IPK created by `tools/webos/build_ipk.sh`. The IPK
verifier rejects a package without it. This source integration has not been
executed; the regular build remains dependent on a compatible private JIT
runner and the pinned toolchains. The SoLoud tap observes that plugin's master
mix, so introducing simultaneous `audioplayers_soloud` voices would require
per-voice isolation before claiming exact-source analysis.

The `com.webos.service.audiooutput` system service is not an app-level route:
LG's webOS OSE API reference says applications must not call it directly. No
system loopback or microphone path is used.

### Native runtime build and admission

The private-JIT release-candidate builder creates the ARMv7 artifact bundle
from the source revision pinned in `native/visualizer/sources.lock.json`; it
sets `PLEZY_WEBOS_VISUALIZER_NATIVE` and
`PLEZY_WEBOS_VISUALIZER_MANIFEST_SHA256` for the pinned IPK packager. The bundle
contains
`libmilkrust_native.so`, `milkrust-source.tar.gz`, `MILKRUST-NOTICES.txt`, and
`milkrust-native.json`. The manifest pins ABI 1, the exact MilkRust source
revision in `native/visualizer/sources.lock.json`, target `webos-arm`, SHA-256
digests for all three payloads, a private-ephemeral-JIT runner policy and the
build run URL. Package inspection checks the bundle is complete, matches those
digests and is ARM ELF32. This is source plumbing and structural inspection;
it does not prove a successful cross-build, runtime loading or TV compatibility.
No generated runtime has been produced in this workspace.

## Qualification still required

Both TV targets remain unqualified. The webOS integration needs the pinned LG
SDK build, source and native artifact admission, then physical-TV checks for
SoLoud and NDL playback boundaries, audio continuity, known/unknown sizes,
unsupported format fallback, authenticated redirects, pause/seek/rate changes,
background suspension, late callbacks, ring overflow, texture leases, EGL and
driver failures, render/audio synchronization and native fidelity. Tizen needs
its SDK/device checks. Emulator results cannot replace physical-TV evidence.
No tests, builds, CI jobs, captures or device runs have been performed for this
source increment. Broader packs cannot be promoted with missing platform
evidence.
