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

ANVIL-S and ANVIL-M at 1080p failed target compilation for both Tensor_G5 and Tensor_G6. The S graph's 59 ops and the M graph's 74 ops each partitioned into one Google Tensor partition before the compiler returned an `INTERNAL` error. The exporter successfully created the float LiteRT model before the AOT plugin failed. The G5 attempts used half truncation; G6 used half truncation and maximum sharding. The earlier ANVIL-S G5 retry also used maximum sharding and still failed. No 1080p Tensor AOT record was produced. Preserved logs are:

- `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/tensor-aot-work-20261029/1080p-anvil-s-google-tensor-g5.error`
- `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/tensor-aot-work-20261029/1080p-anvil-s-google-tensor-g6.error`
- `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/tensor-aot-work-20261029/1080p-anvil-s-google-tensor-g5-max.error`
- `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/tensor-aot-m1080-attempt-20261029/g5.log` and `g5-internal.error`
- `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/tensor-aot-m1080-attempt-20261029/g6.log` and `g6-internal.error`

The follow-up matrix used the exported fixed-shape LiteRT graphs directly and covered every documented combination of truncation (`auto`, `bfloat16`, `half`, `no_truncation`) and sharding (`minimal`, `moderate`, `extensive`, `maximum`) for ANVIL-S and ANVIL-M on Tensor_G5 and Tensor_G6: 64 combinations total. Every combination failed inside the Google compiler plugin with `INTERNAL`; none produced a Tensor AOT model. The [complete result manifest](tensor-1080-option-matrix-2026-10-29.tsv) records each option pair, log and diagnostic path, and diagnostic SHA-256. Full logs and plugin captures remain in task scratch at `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/`; four `no_truncation` plus `maximum` diagnostics from the first follow-up run are in the adjacent `tensor-aot-1080-no-truncation-maximum-20261029` directory.

The M 1080p float intermediate remains at
`/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/tensor-aot-m1080-output-20261029/anvil-m-1080p.tflite`; it is not a Tensor-compiled model. Google's [compilation FAQ](https://developers.google.com/edge/tensor-sdk/tensor-faqs) recommends half truncation plus maximum sharding for compiler memory failures on non-G5 targets, and suggests trying other options or optimizing the model when errors remain vague. The full documented truncation/sharding matrix did not resolve these graphs. Model-graph optimization and a compiler support request remain possible follow-ups; the results establish neither a hardware resolution ceiling nor a successful 1080p workaround.

## Device and distribution gates

`adb devices -l` returned no attached devices. The APK has not been installed or run on a Pixel; Tensor provider ownership, NPU inference, visible output, quality, A/V sync, power, and thermal behavior remain unqualified. No Tensor inference performance data was collected.

The current [Google Tensor SDK terms](https://developers.google.com/edge/litert/next/tensor_ml_terms) define the permitted purpose as developing and optimizing on-device ML for Google-approved use cases of an application on Pixel or other Google-approved Tensor devices (section 2.6). They prohibit publishing Tensor comparison benchmarks (4.16), sharing or publishing Tensor performance data (4.17), and transferring the SDK without written authorization (4.18). The terms reviewed do not expressly settle redistribution of an AOT model produced by the compiler, and no approval record for this app use case is available here. Keep the pack local until the app-use approval and generated-model distribution scope are clarified. No CI was used.

## Remaining gates

- Run the target-matched AOT models on an attached Pixel/Tensor device and qualify provider execution and visible playback.
- On an attached Pixel/Tensor device, qualify the documented 1080p LiteRT GPU then MPV/normal-playback fallback; no device execution has been verified.
- Establish whether the generated model may be included in a PlezyNG release under the accepted terms.
