# Google Tensor AOT model and 1080p compiler evidence — 2026-10-29

This records local model compilation and Android APK packaging only. No CI
workflow, Pixel, or Tensor device was used. The package was not installed, so
this does not establish Tensor NPU execution, playback quality, cadence, sync,
or sustained thermal behavior.

## SDK and pinned inputs

- The user-provided `litert_plugin_compiler.tar.gz` is present at
  `/home/keith/Downloads/litert_plugin_compiler.tar.gz` (375,884,703 bytes;
  SHA-256 `0e99f7683bacaf997c0c502c75a38d5bfc994db6abbe5b51ad24d004eb157b20`).
- The local AOT environment uses `ai-edge-litert==2.3.0`,
  `ai-edge-litert-sdk-google-tensor-nightly==2.3.0.dev20261001`,
  `litert-torch==0.10.0`, and CPU-only PyTorch `2.14.1+cpu`. Google's current
  compatibility table lists those LiteRT versions for Tensor G5/G6 in SDK v2.1.
  The documented G6 memory workaround is half truncation plus maximum
  sharding; the compiler flags also include `google_tensor_int64_to_int32`.
  ([release notes](https://developers.google.com/edge/tensor-sdk/release-notes),
  [compilation flags](https://developers.google.com/edge/tensor-sdk/compilation-flags),
  [compilation FAQ](https://developers.google.com/edge/tensor-sdk/tensor-faqs))
- The model source is ANVIL commit
  `f701fd9b01b9fbb20822637b5d82cac626079e5f`; the pinned weights are revision
  `fa97e30f6aabe897bd4f6f82d971ad607f5d61fa`.

## 720p AOT artifacts and APK

ANVIL-S and ANVIL-M compiled for both targets at 720p. The six-model package
contains the float32 GPU model for each family and four Tensor AOT models:

| Model | Target | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| ANVIL-S 720p | Tensor G5 | 3,852,816 | `3f771ca046c6276681b3d8d244c02abab9f6c92441cdf0f5d2140e2b4618ed72` |
| ANVIL-S 720p | Tensor G6 | 11,572,240 | `483879a47e6bbd6feecdb5ad190221a34d59277e94e3de49f2749d2ce5e9972c` |
| ANVIL-M 720p | Tensor G5 | 7,678,736 | `9d67574c89b9e6729e03eca62964e7c5bd07646703c317e46a651c6e37433145` |
| ANVIL-M 720p | Tensor G6 | 16,964,368 | `25097a7585584cacf64803333ee06541dbaa24efdf3e2986f9ab89b52ea8b464` |

The local pack manifest is
`/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/tensor-aot-pack-20261029/manifest.json`
(SHA-256 `c1567e79b23ab7ddb70cdb7ccd9d8fd84becb7b705eea00f23d6f0b9a25f2c8d`).
It was packaged into
`/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/android-tensor-aot-debug-arm64-20261029.apk`
(971,251,948 bytes; SHA-256
`0be48d90a0040a946a9fb2774988d744c5b5edea19609df7d8a7dd376705d711`). The
embedded model manifest is byte-identical to the pack manifest, and all six
embedded model files match the manifest's byte counts and SHA-256 values.
This APK is a local candidate; it is not published or device-qualified.

The exporter now checks a compiled Tensor AOT file's input/output shapes before
it writes the manifest record. The existing four 720p Tensor outputs were
rechecked through that interface verifier; all expose input `[1,720,1280,6]`
and output `[1,720,1280,3]`.

The exporter keeps its default float32 GPU exports at both 720p and 1080p, but
Tensor AOT compilation now defaults to 720p so a normal Tensor export does not
fail after generating the supported models by attempting the known-failing
1080p graph. Pass `--google-tensor-resolutions 720p 1080p` to request both
Tensor shapes, or `--google-tensor-resolutions 1080p` with `--resolutions
1080p` to retry the 1080p compiler path explicitly.
After a successful export, unlisted `.tflite` files are pruned from the output
directory so Android's wildcard model staging cannot package stale variants.

## 1080p compilation attempts

The 1080p model contract is input `[1,1080,1920,6]`, output
`[1,1080,1920,3]`. The following attempts produced no Tensor AOT model:

| Attempt | Targets and options | Result |
| --- | --- | --- |
| TFLite float32 matrix | ANVIL-S/M × G5/G6 × all four documented truncation modes × all four sharding intensities (64 combinations) | All 64 exited 1 with compiler error `INTERNAL`. |
| TFLite W8A8 | ANVIL-S 1080p × G5/G6, `half` truncation and `maximum` sharding | Both failed in `apply_plugin` with `INTERNAL`. |
| TFLite int64 conversion | ANVIL-S float32 and W8A8 × G5/G6, `half`, `maximum`, `google_tensor_int64_to_int32=True` | All four failed with `INTERNAL`. |
| Direct LiteRT-Torch route | ANVIL-S 1080p × G5/G6 using `experimental_add_compilation_backend`, `half`, and `maximum` | Both target exports skipped the failed compiler plugin; no AOT file was produced. The converted graph reported 157.326 G arithmetic operations. |

The matrix summary is retained at
`/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/tensor-aot-1080-option-matrix-20261029/complete-1080-option-matrix.tsv`
(64 rows, all `INTERNAL`; SHA-256
`66fab2c7c022e292eac45b4bbb6faa64eee8a094ac565bf858a7ed63ec6c54cc`). The
additional W8A8, int64-conversion, and direct-conversion logs and plugin error
files are in sibling `tensor-aot-w8a8-1080-probe-20261029`,
`tensor-aot-int64-1080-probe-20261029`, and
`tensor-aot-pytorch-path-20261029` directories in the same task scratch area.

## Current support boundary

The packaged Tensor AOT records cover ANVIL-S/M at 720p on G5/G6. No 1080p
Tensor record was generated. For a 1080p source, Android therefore has no
matching Tensor AOT model; it can use another available LiteRT hardware route
or the existing playback fallback. This is evidence of the current compiler
and graph limitation, not a claim that Tensor hardware has an inherent 1080p
ceiling. A future compiler or a model graph that compiles at this shape needs
the same manifest, package-integrity, and on-device qualification gates.

At the last local check, `adb devices -l` listed no attached device. The
current artifacts prove model compilation at 720p and APK packaging integrity
only. Tensor runtime execution, visible playback, A/V sync, image quality, and
thermal qualification remain open.
