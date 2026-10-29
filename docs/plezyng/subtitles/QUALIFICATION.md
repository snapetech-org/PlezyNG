# Subtitle inference and playback-capture qualification

This record is a run protocol, not a claim that a device passed. The current execution environment did not expose the target GPU, player binary, or patched libmpv runtime.

## Status

- Android ExoPlayer VOD PCM capture: implemented; device qualification remains separate from source inspection.
- The shared PCM session guard discards active capture after media replacement, explicit seek, audio-track change, profile change, or player disposal. This is source-level lifecycle handling only; no device seek/discontinuity qualification was run.
- Linux, Windows, Apple, and Android MPV PCM capture: the pinned PlezyNG mpv-build source PR carries the ordered `mpv_plezy_audio_tap_read_next` ABI, the Android session bridge, and release-time symbol gates. The PlezyNG app lock still points to the previous checksummed runtime artifacts; shipped capture remains unavailable until the private-JIT publication completes and the resulting artifact digests are promoted into the app lock.
- Android ExoPlayer VOD capture is implemented. Android MPV fallback now routes through the session-leased JNI bridge from the ExoPlayer adapter, but the packaged `libplayer.so` and matching native host still need the ordered-read extension before capture is available. Tizen source now includes both its native C PCM callback and a private-package build of the lockfile-verified CPU Whisper FFI bridge. webOS package source now builds the same CPU-only FFI bridge from its lockfile-verified archive, and the IPK verifier requires the ARM library and its core ABI exports. Neither integration has been built or run on a TV; DRM and codec/device routes that reject PCM export remain unavailable. webOS playback and browser workflows still require a matching WAV; the webOS native media API does not surface PCM, and PlezyNG has no browser `Player` implementation.
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
| Samsung Tizen 6–9 ARM TV | CPU Whisper source build; native `player_h` PCM callback | private-JIT package success, runtime FFI load, WAV ASR, 20-minute VOD capture, codec matrix, caption latency, memory and playback impact |
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

## Resumable WAV jobs

The source now includes a profile-scoped queue with owned audio copies, SHA-256 integrity verification, atomic manifest recovery, 30-second overlapping inference windows, explicit restart recovery, playhead priority, pause/cancel, and external-power/playback-idle policies. Completed or partial results enter the existing review flow for the same item. Native calls finish their current window before cancellation can release resources. This is in-app scheduling, not guaranteed OS background execution. No tests, analyzer, builds, or CI were run for this addition, per owner instruction.

## Editing and alignment diagnostics

Added bounded waveform/spectrogram interval editing, explicit FPS conversion, opt-in text reflow/corrections/filtering, and sync coverage/residual/unmatched-span review. Analysis uses a shared streaming reader supporting integer PCM and IEEE-float WAV. No tests, analyzer, builds, or CI were run. Timing and linguistic quality remain unqualified.
