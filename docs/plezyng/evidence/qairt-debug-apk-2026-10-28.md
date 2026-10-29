# Qualcomm QAIRT Android debug APK — 2026-10-28

This records a full Android debug APK build containing the complete Qualcomm
ANVIL HTP context set. It verifies compilation and package contents only; it
does not establish QNN inference or visible playback on a Snapdragon device.

## Build inputs

- Host: `kspld0`, x86_64 Linux.
- Source tree: branch `codex/android-jvm-target-fix-20261028`, commit
  `c7f56abb4d574acb605c2ed7a44d3bebf51f38ac`, based on main revision
  `5034868dba9962fed4c577de885aaa0aaa7d1865`. The identical build-fix patch is
  now included in this PR as `d45acc80f33538a67a807309ad4d599a5c4d446b` after
  merging current main.
- Android SDK: platform 37.0, build tools 36.1.0, NDK 29.0.14206865 and CMake
  4.1.2. CMake 4.1.2 was installed with the official Android SDK manager.
- QAIRT SDK: 2.51.200.261021 at
  `/var/tmp/plezyng-motion-sdk-acquisition-20261028/qualcomm-qairt-2.51.200.261021/qairt/2.51.200.261021`.
- Context pack:
  `/var/tmp/plezyng-motion-sdk-acquisition-20261028/qualcomm-anvil-contexts-full-20261028`.
  It contains all 22 ANVIL-S/M contexts across 11 SoC mappings. Its manifest
  SHA-256 is
  `5e19899869b87498d42e0688b08fcf235f5afe5a8e48da327c7ca82d1c07d46a`.

The build also fixed the `receive_sharing_intent` Java/Kotlin target mismatch,
a duplicated Kotlin `internal` modifier, and the missing `override` on MPV's
`setVideoRect` implementation.

## Build and package result

The following command succeeded:

```sh
QAIRT_SDK_ROOT=/var/tmp/plezyng-motion-sdk-acquisition-20261028/qualcomm-qairt-2.51.200.261021/qairt/2.51.200.261021 \
PLEZY_ANVIL_CONTEXT_ROOT=/var/tmp/plezyng-motion-sdk-acquisition-20261028/qualcomm-anvil-contexts-full-20261028 \
./gradlew --no-daemon --console=plain :app:assembleDebug
```

Gradle completed 807 actionable tasks: 143 executed and 664 up to date. The
resulting debug APK is retained outside the repository at
`/var/tmp/plezyng-motion-sdk-acquisition-20261028/android-qairt-debug-apk-20261028/app-debug.apk`.

| Check | Result |
| --- | --- |
| APK size | 922,916,790 bytes |
| APK SHA-256 | `db9156087df7b5780eb6e99c18737d17d7e7f7cee99ee739d72dd3fbc03b3d62` |
| Package | `org.snapetech.plezyng`, version `1.0`, min SDK 25, target SDK 36 |
| Context binaries | 22 |
| Packaged context manifest SHA-256 | `5e19899869b87498d42e0688b08fcf235f5afe5a8e48da327c7ca82d1c07d46a` |
| Archive integrity | `unzip -tq` reported no errors |

The APK contains the ARM64 `libQnnHtp.so`, `libQnnHtpPrepare.so`, and
`libQnnSystem.so`; V68/V69/V73/V75/V79/V81 stub libraries; and the matching
Hexagon skeleton assets. The 22 contexts are the same manifest-verified files
documented in the [context staging evidence](qairt-context-staging-2026-10-28.md).

## Qualification limits

This is a large universal **debug** APK, not a release-size or store-upload
qualification. No device installation, QNN graph execution, generated-frame
timing, thermal run, or visible playback was performed. Snapdragon inference,
audio/video synchronization, and image quality remain unqualified.
