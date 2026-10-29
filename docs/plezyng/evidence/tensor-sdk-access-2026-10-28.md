# Google Tensor SDK access and distribution gate — 2026-10-28

The retained SDK acquisition manifest records that a Google Tensor SDK beta
request was submitted through the official form and that the form displayed a
receipt. At that time its status was
`request-submitted-awaiting-review`. The user now reports that the response
arrived and believes the compiler was downloaded. This user report supersedes
the earlier pending status; no new request was submitted.

Local inspection found the public `ai-edge-litert==2.3.0` Python package in the
retained AOT environment, including LiteRT's Google Tensor backend and its
compiler plugin. The separate `ai-edge-litert-sdk-google-tensor-nightly`
package and its SDK libraries are absent from that environment. Searches of
Downloads, the retained motion scratch, and mounted media did not locate a
separate beta compiler archive. The report of approval/download is therefore
recorded, while the archive's path, integrity, and availability to the build
environment remain unverified. No Tensor AOT model pack is in the retained
task evidence.

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

The same Downloads directory also contains `v2.44.0.260225.zip` and
`v2.51.200.261021.zip`. Their ZIP directory entries start at
`qairt/2.44.0.260225/` and `qairt/2.51.200.261021/`, respectively; these are
Qualcomm QAIRT packages, not the Google Tensor SDK. The active system
`python3` environment also reports that
`ai-edge-litert-sdk-google-tensor-nightly` is not installed. These checks do
not inspect private browser history or an unprovided download path.

The exporter now checks for the companion SDK package and compiler shared
libraries before it starts a Tensor model export, so LiteRT's public backend
alone cannot appear ready for AOT compilation.

The official [Tensor SDK compilation guide](https://developers.google.com/edge/tensor-sdk/slm-compilation)
says to extract the approved compiler archive and install the separate
`ai-edge-litert-sdk-google-tensor-nightly` package. This confirms the public
LiteRT backend/plugin alone is not the complete compiler toolchain. The
published
[Tensor SDK terms](https://developers.google.com/edge/litert/next/tensor_ml_terms)
state that software, products, or services created using the SDK may not be
distributed to third parties without Google's prior written authorization.
The same terms prohibit benchmarking Google Tensor against other devices and
publishing performance data. Because the planned model is compiler output, it
should be treated as covered by the distribution restriction until Google
confirms otherwise in writing. That scope assessment is an interpretation of
the published terms, not legal advice.

## Remaining gate

- Locate and verify the user-reported compiler archive and install its
  companion package in the local model-build environment. Do not treat the public
  LiteRT runtime AAR or plugin as the separate beta compiler toolchain.
- Obtain written authorization covering distribution of the compiled ANVIL
  model in PlezyNG before packaging or publishing it.
- Confirm with Google what Tensor performance measurements may be collected
  and published; do not publish comparative results under the current terms.
- Generate a target-matched G5/G6 AOT pack and qualify inference and visible
  playback on the corresponding device after those approvals.
