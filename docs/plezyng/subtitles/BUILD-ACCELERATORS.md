# Optional speech acceleration and local translation

Normal release builds keep Whisper on CPU. GPU compilation is an explicit, opt-in full build because each backend needs its matching native SDK and the deployed machine still needs a compatible driver.

## Build from GitHub Actions

Dispatch the private PlezyNG Release workflow with:

- action=build
- mode=release
- subtitle_gpu_backend=cpu, vulkan, or cuda

The default is cpu. Choosing vulkan installs the pinned LunarG Vulkan SDK 1.4.363.0 for Windows x64 and Linux x64, verifies the published archive SHA-256 (Windows: 94a82d378f7a5e3e54c9db7d2fb7016af136e14ac0a18dbf0f2f67a36352d141; Linux: 197962f5cbf80baf2775a03336a01cee7c8745686c65aaa70d3f751ade4d7e43), and sets FLUTTER_WHISPER_GPU_BACKEND=VULKAN. Choosing cuda installs NVIDIA CUDA Toolkit 13.4.3 components on Windows x64, validates the NVIDIA Authenticode signer, and sets FLUTTER_WHISPER_GPU_BACKEND=CUDA. Linux CUDA and non-x64 builds stay on CPU. Release publishing rejects GPU selections and remains CPU-only.

The SDK installation happens only on the private JIT runner. It does not run from ordinary app builds or configure a consumer machine. The workflow does not install an NVIDIA display driver; GPU use still depends on a compatible driver on the system where the app runs.

## Prerequisites and pinned SDKs

| Target | Build selection | SDK prepared by workflow | Host requirement |
| --- | --- | --- | --- |
| Windows x64 | vulkan | LunarG Vulkan SDK 1.4.363.0, SHA-256 94a82d378f7a5e3e54c9db7d2fb7016af136e14ac0a18dbf0f2f67a36352d141 | Visual Studio 2022 C++ build tools and a Vulkan-capable driver |
| Linux x64 | vulkan | LunarG Vulkan SDK 1.4.363.0, SHA-256 197962f5cbf80baf2775a03336a01cee7c8745686c65aaa70d3f751ade4d7e43 | CMake, Ninja, pkg-config, and a Vulkan-capable driver |
| Windows x64 | cuda | NVIDIA CUDA Toolkit 13.4.3; installer signer checked as NVIDIA Corporation | Visual Studio 2022 C++ build tools and a compatible NVIDIA driver |
| Other targets | cpu | None | No GPU SDK |

Use the official [NVIDIA Windows installation guide](https://docs.nvidia.com/cuda/cuda-installation-guide-microsoft-windows/) and [LunarG SDK downloads](https://vulkan.lunarg.com/sdk/home). CUDA 13.1 and later Windows toolkits do not install the NVIDIA display driver; install the compatible driver separately.

## Build locally

The application dependency pins whisper.cpp through flutter_whisper_ggml. Install the matching toolchain, then set the backend before building.

### Windows x64

~~~powershell
# Install CUDA Toolkit 13.4.3 and a compatible NVIDIA driver first.
$env:FLUTTER_WHISPER_GPU_BACKEND = 'CUDA'
flutter build windows --release

# Or install LunarG Vulkan SDK 1.4.363.0 and build with Vulkan.
$env:FLUTTER_WHISPER_GPU_BACKEND = 'VULKAN'
flutter build windows --release
~~~

### Linux x64

~~~bash
# Install LunarG Vulkan SDK 1.4.363.0 and a compatible Vulkan driver first.
FLUTTER_WHISPER_GPU_BACKEND=VULKAN flutter build linux --release
~~~

CPU builds need no GPU SDK. Backend selection changes which native code is compiled; it cannot enable a GPU in a binary already built for CPU. Whisper device discovery and execution are still runtime-dependent. The app distinguishes CPU selection, provider initialization, and whole-run CPU fallback. Installed Whisper and Sherpa bindings do not expose per-operation device placement, so a successful provider request is not an execution-placement qualification.

## Local desktop subtitle-text translation

Desktop cue translation uses the optional Argos Translate Python runtime. Install argostranslate for the Python interpreter used by PlezyNG, then install the source-to-target package. Example for English to Spanish:

~~~bash
python -m pip install argostranslate
argospm update
argospm install translate-en_es
~~~

Use PLEZY_ARGOS_PYTHON to point PlezyNG at a specific Python executable when python/python3 is not on PATH. Translation runs locally, preserves subtitle timing and markup, and writes a separate SRT. Argos accepts ARGOS_DEVICE_TYPE=cuda; this is an optional request through CTranslate2, not evidence that every cue ran on CUDA. A failed CUDA request retries on CPU. An NVIDIA driver and a CUDA-enabled CTranslate2/Argos installation are required.

## Other targets

- Android Whisper uses CPU/NEON. Android Vulkan and WebGPU are not enabled by the packaged Flutter runtime.
- iOS/macOS Whisper uses CPU/Accelerate. Metal is not enabled.
- Browser Whisper uses WebAssembly CPU; PlezyNG's generated-subtitle attachment flow is not enabled in the browser.
- webOS builds the Linux ARM Whisper FFI bridge as CPU-only from the archive whose version and digest match both `pubspec.lock` and `tools/webos/compatibility.json`. WAV transcription, including Whisper's spoken-audio-to-English mode, is enabled only when the bridge is packaged and its ABI probe succeeds. NDL playback does not expose decoded PCM, and the Argos desktop text translator is not included, so live capture and subtitle-text translation remain unavailable.
- Tizen builds a CPU-only Whisper bridge from the exact lockfile-verified `flutter_whisper_ggml` source and packages it with the app. The Tizen player requests 16 kHz mono PCM before prepare; live captions and WAV workflows are shown only when the bridge is present. No Tizen GPU/NPU backend is compiled or claimed.
- Sherpa ONNX requests Core ML, QNN, and RKNN for its English Moonshine path on supported application targets. Provider initialization or inference failure retries on CPU; the app cannot verify per-node placement.
- Android ExoPlayer VOD supports the existing PCM tap. Android ExoPlayer-to-MPV fallback now routes through the same bounded packet contract when the session-leased JNI bridge is present. Linux, Windows, Apple, and Android MPV source builds now carry a common ordered PCM patch in the pinned PlezyNG mpv-build fork, and the build-fork publication workflow rejects artifacts that do not export `mpv_plezy_audio_tap_read_next`. That source integration is under review; the app still locks the previous checksummed MPV binaries until new artifacts are published and their digests are promoted. Tizen's vendored native `player_h` adapter registers `player_set_media_packet_audio_frame_decoded_cb` before prepare and exposes opt-in 16 kHz mono PCM in a bounded 24-second PTS queue when the codec/device permits it; the private Tizen package build also compiles the matching CPU Whisper FFI runtime from the locked source. DRM and unsupported native routes remain unavailable, and Tizen needs a rebuilt package and TV qualification. webOS uses NDL media playback without a decoded-PCM callback, and browser playback still has no `Player` implementation in this app; those paths require a matching WAV or a separately implemented playback backend.

This document describes build and runtime requests, not measured compatibility. Per-operation placement is unverified by current Flutter inference bindings. The Tizen Whisper source-build integration, webOS Whisper package integration, and Tizen PCM adapter have not yet been built or run on target TVs. No patched platform libmpv artifact or target-device subtitle benchmark has been produced for this change.
