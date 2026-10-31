# Android motion and Tensor AOT APK build evidence — 2026-10-30

This is a local Android debug build and package-integrity record. No CI
workflow or Android device was used. The APK was not installed, so this does
not establish LiteRT provider execution, Tensor NPU placement, visible motion
quality, frame cadence, A/V sync, or sustained playback. This is local
candidate evidence from the feature branch; Tensor AOT model files and their
manifest records remain local pending approval and are not part of main's
default model pack.

## Build

- Source revision: PlezyNG `f7a74967568af04e3ba4d10e6f37b0999b306c9c`, with
  the Android model-staging, runtime-staging, and Tensor model-pack changes
  recorded in local feature-branch commit `3510a7984`. The Tensor model files
  and manifest records are intentionally not part of main pending approval.
- Build: `./gradlew assembleDebug --offline --no-daemon --max-workers=2
  --console=plain` with `PLEZY_LITERT_MODEL_ROOT` unset, so Gradle packaged the
  checked-in default model directory. The local experimental MPV Android AAR
  was supplied with its pinned SHA-256
  `298afc307faae72a2ba81b3440c874a95c765e017f97017cd6f3667e6bae8765`.
- Result: **BUILD SUCCESSFUL** in 9m 58s.
- Package: `org.snapetech.plezyng`, target SDK 36.
- APK: `/mnt/disks/scratch/plezyng-motion-combined-apk-20261030/artifacts/android/app-debug-12-models.apk`
- Size: **787,321,901 bytes**.
- SHA-256: `58dfa50b0524d54d5b2d57ad711a563ff12624111b2c8c0522ed2dd56fc213d9`.
- Build log:
  `/mnt/disks/scratch/plezyng-motion-combined-apk-20261030/logs/android-combined-12-models-build-default.log`.
- APK, manifest, model-hash, runtime-library, and patched-filter verification log:
  `/mnt/disks/scratch/plezyng-motion-combined-apk-20261030/logs/android-12-model-apk-verify.log`.

## Packaged LiteRT models

The APK's `assets/litert/models/manifest.json` is byte-identical to the
feature branch's checked-in candidate `assets/motion_models/litert/manifest.json` (SHA-256
`0e1b17bdb9b1e7bde1ee491a456152fe288631d0206387361878ecf02fa74d88`). All 12
manifest-listed models were read back from the APK and matched their expected
byte counts and SHA-256 values:

| Pack | Variants | Model bytes |
| --- | ---: | ---: |
| Float32 GPU, ANVIL-S/M at 720p/1080p | 4 | 28,344,192 |
| W8A8 generic NPU JIT, ANVIL-S/M at 720p/1080p | 4 | 7,574,992 |
| Google Tensor G5/G6 AOT, ANVIL-S/M at 720p | 4 | 40,068,160 |
| **Total** | **12** | **75,987,344** |

The APK also contains the LiteRT base and GPU runtime libraries for
`arm64-v8a`, `armeabi-v7a`, and `x86_64`. The arm64 package includes the
Google Tensor compiler and dispatch plug-ins; x86_64 includes the OpenVINO
plug-ins. These entries verify package presence only and do not prove a
provider can initialize or execute on a device.

The APK's `lib/arm64-v8a/libmpv.so` has Build ID
`f2eb7b85f3ed4eaec74dc8819b8bca07cf0c2011`. Its retained strings include
`ANVIL H.264 motion-vector video frame interpolation`, `anvil-vfi`,
`plezy_litert_motion_open`, and the Tensor/LiteRT target-selection labels.
This confirms the patched ANVIL filter and its LiteRT bridge are linked into
the arm64 app package. Release stripping removes the internal `vf_anvil`
symbol name, so symbol-name search alone is not a valid presence check.

`zipfile.testzip()` reported no corrupt archive member. The build also passed
the Gradle checks for required LiteRT headers/runtime files, model filenames,
model sizes, and model hashes. The same APK was present at both Gradle output
paths and the files were byte-identical.

## Qualification boundary

This local feature-branch build compiles and packages the Android live
preset-replacement path and its candidate model pack. It is not the repository's
current default pack or a release artifact. There was no device connected or
used for this build, and the APK was not installed.
Google Tensor AOT remains limited to the four 720p records; no 1080p Tensor
graph was produced. Actual Tensor G5/G6 NPU execution, provider selection,
live preset switching during playback, visible output, timing, A/V
synchronization, and thermal behavior remain device-qualification work.
