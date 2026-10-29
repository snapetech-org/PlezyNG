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
