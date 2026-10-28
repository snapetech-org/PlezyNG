# Subtitle inference and playback-capture qualification

This record is a run protocol, not a claim that a device passed. The current execution environment did not expose the target GPU, player binary, or patched libmpv runtime.

## Status

- Android ExoPlayer VOD PCM capture: implemented; device qualification remains separate from source inspection.
- Linux, Windows, Apple, and Android MPV PCM capture: the pinned PlezyNG mpv-build source PR carries the ordered `mpv_plezy_audio_tap_read_next` ABI, the Android session bridge, and release-time symbol gates. The PlezyNG app lock still points to the previous checksummed runtime artifacts; shipped capture remains unavailable until the private-JIT publication completes and the resulting artifact digests are promoted into the app lock.
- Android ExoPlayer VOD capture is implemented. Android MPV fallback now routes through the session-leased JNI bridge from the ExoPlayer adapter, but the packaged `libplayer.so` and matching native host still need the ordered-read extension before capture is available. Tizen's native C player callback is wired in source with a bounded timestamped PCM queue; it needs a rebuilt Tizen app plus TV/codec qualification and is unavailable for DRM or rejected capture routes. webOS and browser players still require a matching WAV; the webOS native media API does not surface PCM, and PlezyNG has no browser `Player` implementation.
- Whisper CUDA/Vulkan and Sherpa Core ML/QNN/RKNN: provider request and whole-run CPU fallback are reported. Current Flutter bindings do not expose per-operation device placement.
- Target hardware runs: pending. Prior RX 7900 XT motion-processing results do not qualify subtitle inference, Whisper, Sherpa, or playback capture.

## Required target matrix

| Platform/device | Build or runtime request | Required evidence |
| --- | --- | --- |
| Linux x86_64, RX 7900 XT | Whisper Vulkan build; patched libmpv capture build | Device identity, driver/runtime versions, native backend logs, operation-level placement trace, caption latency and packet-drop counts |
| Linux x86_64, RX 9070 XT | Same Vulkan build, isolated device selection | Same fields; separate run from RX 7900 XT |
| Windows x64, RTX 3060 | Whisper CUDA and Vulkan builds separately; patched MPV capture artifact | CUDA/Vulkan device identity, operation-level placement, full-run fallback reason, RTF, thermals, PCM continuity and drops |
| macOS, M4 | Core ML Sherpa request and CPU baseline; patched MPV capture artifact | Core ML execution trace by operation, ANE/GPU/CPU assignment if the OS exposes it, memory and thermal data, PCM continuity and drops |
| iPhone/iPad target | CPU Whisper baseline; patched MPV capture artifact | model latency, memory and thermals, PCM continuity and drops on the selected audio route |
| Android Qualcomm NPU target | QNN request and CPU baseline | QNN graph partition/provider trace, CPU-assigned nodes, fallback reason, battery and thermal data |
| Android Rockchip target | RKNN request and CPU baseline | RKNN graph partition/provider trace, CPU-assigned nodes, fallback reason and sustained RTF |
| Intel CPU/GPU/NPU and Steam Deck | Build-specific available providers | Enumerated device plus operation-level execution trace; no inference from device presence alone |

A row is not qualified by successful model load, provider enumeration, a provider string, GPU utilization, or a fast result. A provider can run only part of a graph while unsupported operations execute on CPU.

## Run protocol

1. Record commit, model SHA-256, inference library and native runtime versions, OS/kernel, driver, device PCI or platform identifier, requested provider, and selected audio language.
2. Use the same licensed 10-minute WAV fixture for each backend: clean speech, silence/music, overlap, accented names, and known cue boundaries. Keep the fixture SHA-256 with the report.
3. Run one cold model load, three warm-ups, then ten complete transcriptions. Record cold start, p50/p95 inference time, real-time factor, peak RSS/VRAM, system energy/temperature, output cue count, and CPU fallback state.
4. Capture a backend-native profile with per-operation/provider assignment. For ORT-backed Sherpa, include the provider partition and CPU node list. For Whisper, include a scheduler/backend trace from the compiled whisper.cpp runtime. If the library cannot emit it, mark placement `unverified`; do not promote the backend as hardware-qualified.
5. For capture, play the same local VOD through the active player for at least 20 minutes, including pause, seek, track switch, playback-rate change, and one supported audio format transition. Record packet PTS continuity, ring drops, missing intervals, caption delay, and any playback underruns.
6. Preserve raw logs, report JSON, fixture digest, model/runtime hashes, and exact build commands in a device-specific evidence directory. Never merge runs from two GPUs or providers into one result.

## Report template

~~~json
{
  "commit": "",
  "platform": "",
  "device": "",
  "driver": "",
  "requestedProvider": "",
  "runtimeProvider": "",
  "providerFallback": false,
  "placementEvidence": "unverified",
  "operationTrace": null,
  "modelSha256": "",
  "fixtureSha256": "",
  "coldStartMs": null,
  "inferenceMs": { "p50": null, "p95": null },
  "realTimeFactor": null,
  "peakMemoryBytes": null,
  "packetDrops": null,
  "captionDelayMs": null,
  "playbackUnderruns": null,
  "notes": ""
}
~~~

Do not populate this report from provider enumeration alone. Device-specific results belong under `docs/plezyng/evidence/<device-date>/` after the actual run.
