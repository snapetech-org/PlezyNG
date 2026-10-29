# Samsung Exynos LiteCore SDK acquisition — 2026-10-28

This records acquisition and integrity checks for LiteCore 1.2.1, plus a
follow-up audit of a retained model file. The file's presence does not verify
that a valid LiteCore conversion took place.

## Download

- Host: `kspld0`, local Chrome session.
- Official page: [Exynos Developer Society — LiteCore](https://soc-developer.semiconductor.samsung.com/global/development/ai-litecore/).
- Release: LiteCore SDK 1.2.1 for Ubuntu 24.04. The host OS is EndeavourOS;
  Ubuntu 24.04 is the newest available Linux package from this release.
- Original download:
  `/home/keith/Downloads/ai-litecore-ubuntu2404-v1.2.1 (5).tar.gz`.
- Preserved task copy:
  `/var/tmp/plezyng-motion-sdk-acquisition-20261028/samsung-litecore-1.2.1-20261028/ai-litecore-ubuntu2404-v1.2.1.tar.gz`.
- Size: 51,165,789 bytes.
- SHA-256: `89d1c2c52c2fefa06c4b5ee641a19edf670ce73883994ce132dc3f7e1eb00816`.
- `gzip -t` succeeded. The archive listing includes LiteCore headers and the
  `x86_64-linux` and `arm64-v8a` graph libraries required by the Android build
  script. Samsung did not display a vendor checksum on the release page.
- The user Downloads folder currently contains six copies with this same SHA-256.
  They are duplicate copies of the Exynos LiteCore archive, not the separate
  Google Tensor SDK Beta compiler archive.

## Use status

The retained scratch directory contains
`/var/tmp/plezyng-motion-sdk-acquisition-20261028/samsung-aot-debug-20261028/anvil-s-720p-samsung-E9965.tflite`
(5,240,080 bytes; SHA-256
`c5dc82fee3786eec9c8bb7e4400360ad7b271cfd73fad60b35b805f3559ecc87`). No
model manifest, compiler report, exporter log, or approval record accompanies
it, so its origin and target validity are unknown. Preserve it as an
unqualified artifact; it is not a completed model pack or evidence of Exynos
inference. The repository records do not establish the separate prior written
consent required for the intended model-development work. Confirm that
authorization before any new conversion or use of the artifact. See Samsung's
[AI Model & Software License Agreement](https://soc-developer.semiconductor.samsung.com/ai1/a3f92273-5709-4559-9ab5-b091d5d801d8)
and [Exynos Developer Society terms](https://soc-developer.semiconductor.samsung.com/global/policy/terms/terms-of-use/latest).
