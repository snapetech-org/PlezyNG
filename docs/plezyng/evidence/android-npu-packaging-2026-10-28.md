# Android motion and NPU local package — 2026-10-28

This is a local debug build and package verification. No CI was used or queried.

## Build inputs

- Host: `kspld0` (x86_64 Linux).
- App branch: `codex/android-provider-fallback-20261028`, with the current `main`
  and motion-work branches merged locally.
- MPV Android AAR: locally built from MPV source commit `0aa2868` using the
  Android patch series; AAR SHA-256
  `298afc307faae72a2ba81b3440c874a95c765e017f97017cd6f3667e6bae8765`.
- Media3's build-only FFmpeg headers came from the AAR's pinned MPV source
  checkout at FFmpeg tag `n9.0.2`, commit
  `946fcce07b6dcd0331c8cc609192aeff5e1924f8`. The app build validates the tag
  and source revision before copying headers.
- QAIRT: `2.51.200.261021`. The packaged context manifest SHA-256 is
  `5e19899869b87498d42e0688b08fcf235f5afe5a8e48da327c7ca82d1c07d46a`; it
  contains ANVIL-S/M for 11 Snapdragon targets.
- LiteRT: version `2.3.0`, with checksum-pinned C++ SDK, GPU, Qualcomm,
  MediaTek, Google Tensor, and Intel OpenVINO runtime artifacts.
- Samsung: LiteCore SDK `1.2.1` Ubuntu 24.04 archive, SHA-256
  `89d1c2c52c2fefa06c4b5ee641a19edf670ce73883994ce132dc3f7e1eb00816`.
  LiteRT's Samsung plugins were built from tag `v2.3.0`, with the pinned
  FlatBuffers link fix described in the [Samsung runtime evidence](samsung-litecore-runtime-2026-10-28.md).

## Build and package result

The Android runtime staging task passed with `--rerun-tasks`. It now writes
provider libraries under `build/app/plezy-litert-runtime/jniLibs`, matching the
Android source set and CMake input path. The staged output contains 21 LiteRT,
GPU, vendor provider, and OpenVINO runtime shared libraries, plus Samsung's 16
LiteCore Android libraries as assets.

`flutter build apk --debug --no-pub --target-platform=android-arm64` succeeded
locally with the custom MPV AAR and full QNN and Samsung runtime inputs. The
latest universal debug APK, rebuilt after the MPV cadence precision fixes, was moved to:

`/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/android-motion-npu-debug-cadence-20261028.apk`

| Check | Result |
| --- | --- |
| APK size | 971,257,829 bytes |
| APK SHA-256 | `b5a1f1622dc97ae8805043fb9df76584ae6c46af232e3614279661db334de26e` |
| Package | `org.snapetech.plezyng`, version `3.0.0` / versionCode `159` |
| Android range | min SDK `25`, target SDK `36` |
| Packaged ABIs | `arm64-v8a`, `armeabi-v7a`, `x86_64` |
| LiteRT model entries | 8; all manifest sizes and SHA-256 values verified |
| Qualcomm HTP contexts | 22; source and APK manifest hashes match |
| Samsung plugins | 2; stripped APK ELF Build IDs match the staged plugins |
| Samsung LiteCore assets | 16; all staged SHA-256 values verified |
| arm64 `libmpv.so` | exact SHA-256 match with the custom AAR (`5b930aa5034711b4ac6ed8861ef12fb6d2e4215f1c6fbdb70bd59eda330e0670`) |
| APK ZIP CRC | passed |
| 16 KiB APK zip alignment | passed (`zipalign -c -P 16 4`) |

The Google Tensor provider runtime plugin is packaged, but this APK has no
`Tensor_G5` or `Tensor_G6` AOT model. The Exynos-named file in retained scratch
has no compiler report, manifest, or approval record and is not treated as a
usable Samsung model pack.

## Local checks

- `flutter test --no-pub test/services/android_anvil_provider_status_test.dart`:
  3 tests passed.
- `flutter test --no-pub test/services/motion_clarity_service_test.dart`:
  2 tests passed, covering exact fractional minterpolate rates and non-finite
  display-rate fallback.
- `flutter test --no-pub test/screens/video_player/player_output_format_test.dart`:
  10 tests passed, including NaN and infinite container rates.
- `dart analyze` on the motion service, model-pack service, and performance
  overlay report files: no issues found.
- MPV Android glue tests: 3/3 passed; MediaCodec timing/admission tests passed.
  Logs are retained under
  `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/`.
- Gradle staging and successful Flutter build logs are retained in the same
  task-scratch directory. The latest verification report is
  `android-npu-apk-verification-cadence-20261028.txt`. The earlier verified APK
  remains at `android-motion-npu-debug-20261029.apk` with SHA-256
  `03b18cd70b09b24db059a76029ab0c795570e92e6abb862b86a8c9f81a0602cb`.

## Qualification boundary

`adb devices -l` listed no attached devices. The APK was not installed; QNN,
LiteRT, and Samsung inference, NPU selection, frame-generation latency, visible
quality, A/V synchronization, power/thermal behavior, and asynchronous provider
failover remain unqualified on device. Samsung AOT model development remains
gated by the separate prior written consent recorded in the LiteCore acquisition
evidence. Downloads contains six `ai-litecore` archives and two generic ZIPs
whose contents identify them as Qualcomm QAIRT. No Google Tensor compiler
archive or companion Python package is available in the checked local
environment, and no Google Tensor AOT pack was generated. This is a debug
package, not a release artifact, and the pinned MPV artifact lock was not
changed.
