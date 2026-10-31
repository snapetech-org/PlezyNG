# Android Tensor AOT default-pack build evidence — 2026-10-31

This local debug build packages the checked-in 12-model LiteRT pack, including
Google Tensor G5/G6 AOT models, and compiles the Android live-preset path. The
build ran outside CI. No Android device was connected or used, and the APK was
not installed; this records compilation and package integrity, not NPU
execution or playback quality.

## Build

- Branch: `codex/motion-tensor-aot-20261031`, built from the working tree based
  on PlezyNG `5f04dea99`, then rebased onto `f6a731639` before publication.
  The rebased commit only adds parallel CI/support changes outside the Android
  app and model pack.
- Command from `android/`:
  `./gradlew assembleDebug --offline --no-daemon --max-workers=2 --console=plain`
- Result: **BUILD SUCCESSFUL in 11m** (1,320 actionable tasks).
- APK outputs:
  - `build/app/outputs/apk/debug/app-debug.apk`
  - `build/app/outputs/flutter-apk/app-debug.apk`
- The two output APKs are byte-identical.
- Retained APK:
  `/mnt/disks/scratch/plezyng-motion-tensor-aot-20261031/artifacts/plezyng-android-debug-tensor-aot.apk`
- Size: **787,301,569 bytes**.
- SHA-256: `534266253287df019e03c69e945a8d963c4befb9b6cf439f023f6585ca776cc9`.
- Build log:
  `/mnt/disks/scratch/plezyng-motion-tensor-aot-20261031/logs/android-default-aot-pack-build.log`.
- APK verification record:
  `/mnt/disks/scratch/plezyng-motion-tensor-aot-20261031/logs/android-tensor-aot-default-pack-apk-verification.json`.

## Model pack

The APK's `assets/litert/models/manifest.json` is byte-identical to the
checked-in `assets/motion_models/litert/manifest.json` (SHA-256
`de0cf76d8e325074646d424f3e25a219996e5690fc475bad2d77c1b2b277f623`). The
APK archive passed `zipfile.testzip()`. Every manifest-listed `.tflite` file
was read from the APK and matched its declared size and SHA-256:

| Pack | Variants | Model bytes |
| --- | ---: | ---: |
| Float32 GPU, ANVIL-S/M at 720p/1080p | 4 | 28,344,192 |
| W8A8 NPU JIT, ANVIL-S/M at 720p/1080p | 4 | 7,574,992 |
| Google Tensor G5/G6 AOT, ANVIL-S/M at 720p | 4 | 40,068,160 |
| **Total** | **12** | **75,987,344** |

The four target-specific AOT payloads are:

| Model | Bytes | SHA-256 |
| --- | ---: | --- |
| ANVIL-M 720p, Tensor G5 | 7,678,736 | `9d67574c89b9e6729e03eca62964e7c5bd07646703c317e46a651c6e37433145` |
| ANVIL-M 720p, Tensor G6 | 16,964,368 | `25097a7585584cacf64803333ee06541dbaa24efdf3e2986f9ab89b52ea8b464` |
| ANVIL-S 720p, Tensor G5 | 3,852,816 | `3f771ca046c6276681b3d8d244c02abab9f6c92441cdf0f5d2140e2b4618ed72` |
| ANVIL-S 720p, Tensor G6 | 11,572,240 | `483879a47e6bbd6feecdb5ad190221a34d59277e94e3de49f2749d2ce5e9972c` |

The arm64 APK contains LiteRT's Tensor compiler and dispatch libraries:
`libLiteRtCompilerPlugin_google_tensor.so` and
`libLiteRtDispatch_GoogleTensor.so`. Their presence confirms packaging only.
The APK also contains `libmpv.so` for arm64.

## Qualification boundary

The default Android pack now selects target-specific G5/G6 artifacts by the
device SoC record; generic Tensor JIT remains unavailable. The compiler pack
contains 720p Tensor records only. The build does not show that a Tensor device
can initialize the runtime, execute on its NPU, present generated frames, or
maintain cadence, A/V sync, image quality, and thermal limits. No device was
available for those measurements.
