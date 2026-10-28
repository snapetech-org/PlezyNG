# TV visualization integration

Status: Tizen PCM, EGL/texture host and optional artifact packaging source from
closed [PR #74](https://github.com/snapetech-org/PlezyNG/pull/74) is retained on
this continuation branch for re-review. It has not been compiled or run. webOS
still needs a supported PCM source and native host. Neither platform is
release-qualified.

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

## Qualification still required

Both targets remain open in `all-native-hosts-v1`. After execution is authorized,
use compatible private ephemeral JIT runners and physical TVs to exercise
ordinary playback with and without the renderer library; offload/protected/
unsupported outputs; exact-source rebinding; pause/seek/rate/track changes;
buffering; suspend/restore; late callbacks; pending pixel leases; allocation
limits; context loss and driver failures. Compare captured output and audio
synchronization against the approved reference corpus. Emulator results cannot
replace physical TV evidence. No tests, builds, CI jobs or device runs have been
performed for this increment. Broader packs cannot be promoted with missing
platform evidence.
