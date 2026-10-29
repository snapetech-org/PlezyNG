# Google Tensor AOT toolchain gate — 2026-10-29

## Export route and SDK acquisition

PlezyNG's `scripts/motion/export_android_litert_models.py` has a Tensor_G5/G6 AOT route. Android only selects an AOT record whose `soc_model` matches the device; Google Tensor is not selected through generic LiteRT JIT.

The user-provided compiler archive was found at `/home/keith/Downloads/litert_plugin_compiler.tar.gz` on 2026-10-29. It is 375,884,703 bytes with SHA-256 `0e99f7683bacaf997c0c502c75a38d5bfc994db6abbe5b51ad24d004eb157b20`. Archive inspection found 2,445 members and 1,026,903,316 uncompressed bytes, all under `google_tensor_ml_sdk/`, with no path traversal or symlink entries. The archive was extracted to task scratch at:

`/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/tensor-sdk-google-tensor-6.1.0/`

The compiler ran in an isolated Python 3.11 environment with the pinned `ai-edge-litert==2.3.0` and `ai-edge-litert-sdk-google-tensor-nightly==2.3.0.dev20261001` packages. The ANVIL source was pinned to `f701fd9b01b9fbb20822637b5d82cac626079e5f`; its model weights were pinned to `fa97e30f6aabe897bd4f6f82d971ad607f5d61fa`.

## Successful local exports

ANVIL-S and ANVIL-M at 720p compiled for both targets. Each compiler report says the entire graph was offloaded to one partition. The exporter’s LiteRT interface checks passed. This is compiler and file-interface evidence; it does not prove NPU execution or playback.

| Model | Target | Ops in partition | Bytes | SHA-256 |
| --- | --- | ---: | ---: | --- |
| ANVIL-S 720p | Tensor_G5 | 57 / 57 | 3,852,816 | `3f771ca046c6276681b3d8d244c02abab9f6c92441cdf0f5d2140e2b4618ed72` |
| ANVIL-S 720p | Tensor_G6 | 57 / 57 | 11,572,240 | `483879a47e6bbd6feecdb5ad190221a34d59277e94e3de49f2749d2ce5e9972c` |
| ANVIL-M 720p | Tensor_G5 | 72 / 72 | 7,678,736 | `9d67574c89b9e6729e03eca62964e7c5bd07646703c317e46a651c6e37433145` |
| ANVIL-M 720p | Tensor_G6 | 72 / 72 | 16,964,368 | `25097a7585584cacf64803333ee06541dbaa24efdf3e2986f9ab89b52ea8b464` |

The complete local pack, including the matching float GPU variants, is retained at:

`/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/tensor-aot-pack-20261029/`

Its normalized `manifest.json` SHA-256 is `c1567e79b23ab7ddb70cdb7ccd9d8fd84becb7b705eea00f23d6f0b9a25f2c8d`. Each model file’s manifest byte count and digest were rechecked after the provider keys were normalized to `google-tensor-g5` and `google-tensor-g6`. The pack remains in task scratch and is not checked into the source tree. A separate local arm64 debug APK packages this pack; it is not a release artifact.

## Local Android package

The app build uses `PLEZY_LITERT_MODEL_ROOT` to stage an external LiteRT model pack. The local build used that variable with the pack above and Gradle's `plezyExperimentalMpvFfmpegSourceRoot` override pointing at the existing FFmpeg `n9.0.2` checkout (`946fcce07b6dcd0331c8cc609192aeff5e1924f8`), avoiding a second source download.

The resulting APK is retained at:

`/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/android-tensor-aot-debug-arm64-20261029.apk`

It is 971,251,948 bytes with SHA-256 `0be48d90a0040a946a9fb2774988d744c5b5edea19609df7d8a7dd376705d711`. Its `assets/litert/models/manifest.json` has the same SHA-256 as the local pack, and all six embedded GPU/AOT model entries passed byte-count and SHA-256 checks. The APK also contains `libLiteRtCompilerPlugin_google_tensor.so` and `libLiteRtDispatch_GoogleTensor.so` for arm64. `zipalign -c -P 16 4` passed. This verifies local packaging and manifest integrity only; the APK has not been installed or run on a Pixel.

## 1080p compiler failures

ANVIL-S 1080p did not compile for Tensor_G5 or Tensor_G6. All 59 graph ops partitioned, then the compiler returned an `INTERNAL` error during target compilation. Tensor_G6 used half truncation and maximum sharding; Tensor_G5 was retried with both flags and still failed. Preserved logs are:

- `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/tensor-aot-work-20261029/1080p-anvil-s-google-tensor-g5.error`
- `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/tensor-aot-work-20261029/1080p-anvil-s-google-tensor-g6.error`
- `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/tensor-aot-work-20261029/1080p-anvil-s-google-tensor-g5-max.error`

Google's [compilation FAQ](https://developers.google.com/edge/tensor-sdk/tensor-faqs) describes internal compiler crashes related to memory sharding and truncation for non-G5 targets and recommends half truncation plus maximum sharding. Those flags did not resolve this G6 compile. The G5 retry also failed, so the evidence does not establish a hard resolution limit or a successful 1080p workaround.

## Device and distribution gates

`adb devices -l` returned no attached devices. The APK has not been installed or run on a Pixel; Tensor provider ownership, NPU inference, visible output, quality, A/V sync, power, and thermal behavior remain unqualified. No Tensor inference performance data was collected.

The current [Google Tensor SDK terms](https://developers.google.com/edge/litert/next/tensor_ml_terms) limit SDK use to Google-approved Pixel/Tensor use cases, restrict transfer of the SDK, and prohibit sharing or publishing Tensor performance data. The specific release-distribution permission for the compiled model and app has not been established. Keep the pack local until that question is resolved. No CI was used.

## Remaining gates

- Run the target-matched AOT models on an attached Pixel/Tensor device and qualify provider execution and visible playback.
- Resolve the 1080p ANVIL-S compiler failures or document the supported Tensor resolution/model fallback.
- Establish whether the generated model may be included in a PlezyNG release under the accepted terms.
