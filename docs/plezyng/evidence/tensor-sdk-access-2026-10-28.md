# Google Tensor AOT toolchain gate — 2026-10-29

## Project path

PlezyNG has a Google Tensor AOT export route in `scripts/motion/export_android_litert_models.py`. It compiles the fixed-shape ANVIL float TFLite graphs for Tensor_G5 and/or Tensor_G6. Android only selects a matching manifest record marked `execution: aot`; Tensor is not exposed through the generic on-device JIT route. No Tensor AOT model record has been generated or exercised on a Pixel device.

The current exporter requirements pin `ai-edge-litert==2.3.0` and `ai-edge-litert-sdk-google-tensor-nightly==2.3.0.dev20261001`. The user-provided AOT notebook installs the stable companion package `ai-edge-litert-sdk-google-tensor==2.3.0`. I downloaded both official PyPI source distributions for metadata inspection into task scratch (not installed). Both expose the `ai_edge_litert_sdk_google_tensor` import module, use the same `data/` SDK path and identify compiler artifact release 6.1.0. The existing nightly pin is retained because it matches Google's current setup guide and the stable LiteRT 2.3.0 configuration. See the [Tensor SDK setup guide](https://developers.google.com/edge/tensor-sdk/slm-compilation), [Google Tensor release notes](https://developers.google.com/edge/tensor-sdk/release-notes), and the official [stable](https://pypi.org/project/ai-edge-litert-sdk-google-tensor/2.3.0/) and [nightly](https://pypi.org/project/ai-edge-litert-sdk-google-tensor-nightly/2.3.0.dev20261001/) package metadata.

## Local acquisition check

At 2026-10-29 06:33 UTC, `/home/keith/Downloads` contained the AOT notebook but no `litert_plugin_compiler.tar.gz`, matching compiler archive, or browser partial. A same-size search of Downloads, the local package cache, and `/tmp` also found no compiler archive. The Python companion package alone does not include the compiler. Its Google-published source constructs the official release 6.1.0 URL; a HEAD request and a one-byte ranged GET from `kspld0` both returned HTTP 404. The compiler archive therefore remains unavailable to the exporter environment at this check, and no Tensor AOT model pack has been produced.

The archive and the LiteRT Android runtime/plugin are distinct inputs. Google’s current [Tensor SDK setup guide](https://developers.google.com/edge/tensor-sdk/slm-compilation) requires the compiler archive and a companion Python package. The [LiteRT NPU guide](https://developers.google.com/edge/litert/next/npu) describes Tensor as AOT-only in beta; it does not support on-device JIT.

## Terms and distribution

Google’s online [Tensor SDK terms](https://developers.google.com/edge/litert/next/tensor_ml_terms), last updated 2026-10-28, define the purpose as development and optimization of on-device ML for Google-approved Pixel/Tensor use cases. They restrict transferring the SDK to third parties, and prohibit externally publishing Tensor performance data, including cross-device comparisons. No Tensor performance data has been collected or published for this work.

The stable PyPI companion package’s source archive also contains a `TERMS_OF_USE.md` that says the compiler is governed by a separate license and includes a prior written authorization requirement for distributing software created using the SDK. The current online terms and the package-embedded text differ. The compiler archive and its separate license are not available here, so the precise distribution rights for a compiled model/app have not been established. Keep Tensor artifacts local until the applicable accepted terms and any required Google authorization are confirmed; do not publish Tensor performance data.

## Remaining gates

- Make the authorized compiler archive available locally, verify its archive contents, and install the pinned companion package with `GOOGLE_TENSOR_SDK_BETA` set to that path.
- Generate the target-matched G5/G6 AOT model pack and check its manifest and hashes.
- Confirm an attached target Pixel/Tensor device, then qualify provider execution and visible playback without publishing Tensor performance data.
- Establish the applicable model/app distribution terms before adding a Tensor pack to any externally distributed artifact.
