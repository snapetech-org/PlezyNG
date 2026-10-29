# Google Tensor SDK access and distribution gate — 2026-10-28

The retained SDK acquisition manifest records that a Google Tensor SDK beta
request was submitted through the official form and that the form displayed a
receipt. At that time its status was
`request-submitted-awaiting-review`. The user now reports that the response
arrived and believes the compiler was downloaded. This user report supersedes
the earlier pending status; no new request was submitted.

Local inspection found the public `ai-edge-litert==2.3.0` Python package in the
retained AOT environment, including LiteRT's Google Tensor backend and its
Android runtime plugin. The separate
`ai-edge-litert-sdk-google-tensor-nightly` compiler package and its SDK archive
are not present in the active environment. The user reports approval and a
download; that report is retained, while the archive's path and availability to
the model-build environment remain unverified. No Tensor AOT model pack is in
the retained task evidence.

Follow-up after the user reported the response and download had arrived:
`/home/keith/Downloads` contains six byte-identical copies of
`ai-litecore-ubuntu2404-v1.2.1.tar.gz`, each SHA-256
`89d1c2c52c2fefa06c4b5ee641a19edf670ce73883994ce132dc3f7e1eb00816`. This is
Samsung Exynos AI LiteCore, not the separate Google Tensor Beta compiler
archive. Google's [compiler setup guide](https://developers.google.com/edge/tensor-sdk/slm-compilation)
requires the approved compiler archive and the companion
`ai-edge-litert-sdk-google-tensor-nightly` package. The local APK now includes
the Google Tensor LiteRT runtime plugin, but no Tensor_G5 or Tensor_G6 AOT
model record is present. No new beta request was submitted.

The latest local check of `/home/keith/Downloads` still finds no Google Tensor
compiler archive. It contains `v2.44.0.260225.zip` and
`v2.51.200.261021.zip`. Their ZIP directory entries start at
`qairt/2.44.0.260225/` and `qairt/2.51.200.261021/`, respectively; these are
Qualcomm QAIRT packages, not the Google Tensor SDK. The active system
`python3` environment also reports that
`ai-edge-litert-sdk-google-tensor-nightly` is not installed. The Google Tensor
LiteRT runtime AAR and provider plug-in already staged in the Android build
cache are distinct from the beta compiler archive. These checks do not inspect
private browser history or an unprovided download path.

The exporter now checks for the companion SDK package and compiler shared
libraries before it starts a Tensor model export, so LiteRT's public backend
alone cannot appear ready for AOT compilation.

The official [Tensor SDK compilation guide](https://developers.google.com/edge/tensor-sdk/slm-compilation)
says to extract the approved compiler archive and install the separate
`ai-edge-litert-sdk-google-tensor-nightly` package. This confirms the public
LiteRT backend/plugin alone is not the complete compiler toolchain. The
published
[Tensor SDK terms](https://developers.google.com/edge/litert/next/tensor_ml_terms)
limit SDK use to developing Android applications and machine-learning
experiences for Google-approved use cases on Pixel and other Google-approved
devices. They prohibit redistribution of the SDK itself without written
authorization, benchmarking Tensor against other devices and publishing those
comparisons, and sharing or publishing Tensor performance data. The terms do
not expressly establish a blanket restriction on distributing a compiled
model; the model's status and the approved-use-case scope should be confirmed
with Google before packaging it.

## Recheck during resumed work — 2026-10-28

A second search of `/home/keith/Downloads` found no Google Tensor compiler
archive or Tensor SDK wheel. The recent SDK-like files are six 51 MB
`ai-litecore-ubuntu2404-v1.2.1*.tar.gz` archives (Samsung Exynos LiteCore),
`v2.51.200.261021.zip` (2.97 GB) and `v2.44.0.260225.zip` (1.56 GB), whose
contents identify them as Qualcomm QAIRT. The latest of these was downloaded
at 21:18 local time; there is no later compiler archive in Downloads. The
`ai-edge-litert-sdk-google-tensor-nightly` package is still absent from the
active model-build environment.

PlezyNG already has the Tensor AOT export route in
`scripts/motion/export_android_litert_models.py` and pins the companion package
in `scripts/motion/requirements-android-litert-google-tensor-aot.txt`. The
exporter compiles the generated float TFLite graphs for Tensor_G5 and/or
Tensor_G6. The Android runtime only selects a Google Tensor model record marked
`execution: aot` that matches the device SoC, and it does not offer the Tensor
provider through the generic JIT path. The route is ready for compiler-backed
export, but there is still no AOT model record or connected Android device.

Google's current [Tensor compilation guide](https://developers.google.com/edge/tensor-sdk/compilation-flags)
describes AOT compilation of TFLite models; the [LiteRT NPU guide](https://developers.google.com/edge/litert/next/npu)
says Google Tensor supports AOT through `CompiledModel` and does not support
on-device JIT in beta. The [Tensor Beta setup guide](https://developers.google.com/edge/tensor-sdk/slm-compilation)
requires both the approved compiler archive and
`ai-edge-litert-sdk-google-tensor-nightly`. The public SDK page links to an
access request form, not to a public compiler archive.

The current [Tensor SDK terms](https://developers.google.com/edge/litert/next/tensor_ml_terms)
limit use to Google-approved application use cases on Pixel or other
Google-approved Tensor devices, prohibit redistributing the SDK without
written authorization, and prohibit externally publishing Tensor performance
data or cross-device benchmarks. The reviewed terms do not explicitly state a
general rule for distribution of a compiled model; obtain clarification for
the PlezyNG model pack and confirm the approved use case before distribution.

## Remaining gate

- Locate and verify the user-reported compiler archive and install its
  companion package in the local model-build environment. Do not treat the public
  LiteRT runtime AAR or plugin as the separate beta compiler toolchain.
- Confirm that the PlezyNG ANVIL use case is within the approved Tensor SDK
  scope and clarify the distribution terms for the compiled model before
  packaging it.
- Confirm with Google what Tensor performance measurements may be collected
  and published; do not publish comparative results under the current terms.
- Generate a target-matched G5/G6 AOT pack and qualify inference and visible
  playback on the corresponding device after those approvals.
