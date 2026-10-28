# Samsung Exynos LiteCore SDK acquisition — 2026-10-28

This records acquisition and integrity checks for LiteCore 1.2.1. It does not
record SDK compilation or model conversion.

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

## Use status

No LiteCore compiler or model conversion was run. Samsung's download terms make
software downloads subject to an additional EULA, and the model-development
license requires prior written consent for the intended model work. That
consent has not been recorded. The SDK remains preserved for use after the
authorization condition is resolved; see Samsung's [AI Model & Software License
Agreement](https://soc-developer.semiconductor.samsung.com/ai1/a3f92273-5709-4559-9ab5-b091d5d801d8)
and the [Exynos Developer Society terms](https://soc-developer.semiconductor.samsung.com/global/policy/terms/terms-of-use/latest).
