# Local MPV 0161 and WebGPU PME integration smoke

**Date:** 2026-10-31
**Host:** `kspld0`
**Compute GPU:** AMD Radeon RX 7900 XT (`0x1002:0x744c`)
**Desktop/output GPU:** AMD Radeon RX 9070 XT (`0x1002:0x7550`)

## Artifacts and routing

The local app bundle is `build/pme-webgpu-app/bundle/plezy`; it contains the PME
runtime, ONNX Runtime 1.27.1, the WebGPU Plugin EP 0.5.0, and the WebGPU provider
manifest. The MPV library comes from the retained Linux x86_64 0161 candidate:

| Item | Value |
| --- | --- |
| Candidate key | `d142165ec420` |
| Source MPV commit | `4fe0b706` |
| Archive | `/mnt/disks/scratch/plezyng-motion-qualification-20261028/mpv-0161-local-candidates-20261029/artifacts/linux-x86_64/libmpv-linux-d142165ec420-x86_64.tar.zst` |
| SHA-256 | `e21549437c7c28809e66151ecd144a6b0bcae825731a6edd280627245dc8681c` |

The archive passed `zstd -t` before extraction into the local prefix
`build/pme-webgpu-mpv-prefix`. Launching `ldd` on the PlezyNG bundle through
`scripts/motion/with_rx7900_motion_gpu.sh` resolved `libmpv.so.2` to that prefix
with no unresolved libraries. The launcher selected the RX 7900 XT by ROCm UUID
and Vulkan ID and left MPV's display renderer selection unchanged. Three Ubuntu
runtime libraries required by this candidate were copied from the earlier local
app bundle into a prefix-local support directory; no host libraries or release
packages were changed.

The system `/usr/bin/mpv` is statically linked and does not use this candidate.
The smoke therefore used a temporary C API client linked directly to the
candidate `libmpv.so.2`, with the PME, ONNX Runtime, and provider manifest from
the PlezyNG app bundle.

## Input and observed behavior

The client played a task-owned synthetic clip at
`build/pme-webgpu-motion-smoke-1280x720-24fps-12s.mp4` (H.264, 1280×720,
24 fps, 12 seconds, with an AAC track). It used software decoding with FFmpeg
motion-vector export enabled, `vo=null`, `ao=null`, the 540p ANVIL-S Performance
model, and CPU fallback disabled.

The native filter registered and logged:

```text
PME compute pinned to AMD Radeon RX 7900 XT (GPU-6bdce6ea1d388c5c, WebGPU ID 0x1002:0x744c)
Plezy Motion Engine neural interpolation filter initialized
PME: WebGpuExecutionProvider on AMD ready (model 960x540, source 1280x720, scale 1.333x)
PME: three Neural deadlines were missed within two seconds; using MPV smoothing for 10 seconds
FILE_LOADED
END_FILE
```

The client exited successfully. After end-of-file the filter metadata properties
were no longer available, so this run did not record generated-frame count or
inference p95. During the run the RX 7900 XT was already busy; after it, the card
reported 98% GPU busy and 20.47 GB VRAM used. The RX 9070 XT reported 12% busy
and 5.80 GB VRAM used. No process was stopped or moved.

This confirms the patched MPV filter, bundled WebGPU provider, selected compute
GPU, and deadline fallback are connected. The 7900 XT contention caused the
governor to fall back to MPV smoothing, so the result does not qualify sustained
Neural timing. The null video/audio outputs also leave visible display cadence,
A/V sync, image quality, and the RX 9070 XT presentation path untested. The app
binary itself was inspected with `ldd` but not launched. No CI or release
publication was used, and the PlezyNG MPV lock remains unchanged.
