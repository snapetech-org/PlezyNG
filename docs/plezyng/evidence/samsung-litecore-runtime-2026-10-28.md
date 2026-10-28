# Samsung Exynos LiteCore runtime and APK integration — 2026-10-28

This records SDK acquisition, provider-plugin compilation, and Android APK
packaging. It does not record Samsung model conversion, Exynos device
inference, or visible playback qualification.

## SDK acquisition

- Host: `kspld0`, authenticated local Chrome session.
- Official release page: [Exynos Developer Society — LiteCore](https://soc-developer.semiconductor.samsung.com/global/development/ai-litecore/).
- Package: LiteCore SDK 1.2.1 for Ubuntu 24.04.
- Original download: `/home/keith/Downloads/ai-litecore-ubuntu2404-v1.2.1 (5).tar.gz`.
- Preserved archive: `/var/tmp/plezyng-motion-sdk-acquisition-20261028/samsung-litecore-1.2.1-20261028/ai-litecore-ubuntu2404-v1.2.1.tar.gz`.
- Archive size: 51,165,789 bytes.
- Archive SHA-256: `89d1c2c52c2fefa06c4b5ee641a19edf670ce73883994ce132dc3f7e1eb00816`.
- `gzip -t` succeeded. Samsung did not show a vendor checksum; this SHA-256
  identifies the acquired archive, not a vendor-published digest.
- Extracted SDK root: `/var/tmp/plezyng-motion-sdk-acquisition-20261028/samsung-litecore-1.2.1-20261028/sdk/exynos-ai-litecore-v1.2.1`.

## LiteRT plugin build

- LiteRT source tag: `v2.3.0`.
- LiteRT source commit: `4352e261d3f1b3cda00345db5dbd75859d3bf0d3`.
- Bazel: `7.7.0`.
- Android NDK: `27.2.12479018`.
- Build script: `scripts/motion/build_android_samsung_litert_runtime.sh`.
- LiteRT v2.3.0's Samsung RMSNorm builder included FlatBuffers headers but
  linked only the header-only `runtime_cc` target; its inline number parser
  references `ClassicLocale::instance_`, defined in FlatBuffers' compiled
  library. The new pinned patch adds `@flatbuffers//:flatbuffers` to that
  builder. The script applies the patch in a detached temporary worktree and
  leaves the supplied LiteRT checkout unchanged.
- Bazel built the compiler and dispatch plugin targets successfully (511
  actions). The staged output is
  `/var/tmp/plezyng-motion-sdk-acquisition-20261028/samsung-litecore-runtime-20261028`.
- The stage contains both LiteRT Samsung plugins plus all 16
  `lib/arm64-v8a/*.so` files from LiteCore. All 18 staged libraries are
  AArch64 ELF files and pass the generated `SHA256SUMS` manifest.
- LiteRT compiler plugin SHA-256 before Android packaging:
  `5f1b27a1ab649298ecf7212bd68d2a84ab3320273da1cb589d2ae1390f724459`.
- LiteRT dispatch plugin SHA-256 before Android packaging:
  `f08656a642c46e7b06b64fbe1e0800de9e73b0b69c1641b87995562b4a16840f`.

## APK packaging

- App source: `codex/qairt-context-fix-20261028` at
  `570554e63c415b9b8f7937f573d14033e800996e`.
- Gradle task: `:app:assembleDebug` — succeeded.
- Preserved APK:
  `/var/tmp/plezyng-motion-sdk-acquisition-20261028/android-samsung-litecore-debug-apk-20261028/app-debug.apk`.
- APK size: 991,130,732 bytes.
- APK SHA-256: `7a230e88b136e80662fac9f5bc935cf4e542114c40702327b5dd07f736296d2a`.
- ZIP archive integrity check succeeded. The APK contains 22 Qualcomm HTP
  contexts, nine QAIRT arm64 shared libraries, and all eight current LiteRT
  model files. The 16 LiteCore shared libraries remain APK assets and match
  their staged SHA-256 values. Android's native-library strip step changes the
  two LiteRT JNI plugin files during packaging; their resulting APK digests
  are recorded below.
- Packaged compiler plugin SHA-256:
  `e9dcd206d76a89039f87777e4dcd3529e8b435eb61775233cf782eb489b58ab7`.
- Packaged dispatch plugin SHA-256:
  `c198aaaf95210093ed2893b6fd5416ecec58d99cee6ce396124e62d5d197c8e2`.

## Qualification limits

This proves that the Samsung plugins and LiteCore runtime can be staged and
packaged with the Android app. It does not prove LiteRT session creation,
NPU partitioning, frame inference, output quality, timing, thermal stability,
or audio/video sync on an Exynos device. Samsung ANVIL AOT model conversion was
not run; the separate prior written consent for model development remains
unrecorded. Samsung E9955/E9965 model selection and visible playback still need
their exact model pack and physical-device qualification.
