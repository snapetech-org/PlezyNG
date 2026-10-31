# Android live preset-switch debug build (2026-10-30)

## Build

Built locally on `kspld0` from branch `codex/motion-engine-w8a8-20261030`, outside CI:

```sh
nice -n 19 ionice -c 2 -n 7 ./gradlew :app:assembleDebug --no-daemon --max-workers=2
```

Gradle completed with `BUILD SUCCESSFUL in 6m 50s` and 806 actionable tasks (425 executed, 381 up-to-date). The build now compiles the Android live Performance/Balanced/Quality switching path. The `receive_sharing_intent` Java/Kotlin target mismatch was resolved by aligning Android library compilation to JVM 17; two Kotlin declarations in the app were also corrected.

## Packaged artifact

- Path in the scratch worktree: `build/app/outputs/apk/debug/app-debug.apk`
- Retained standalone copy: `/mnt/disks/scratch/plezyng-motion-runtime-20261030/artifacts/android/app-debug.apk`
- Size: 677,807,075 bytes
- SHA-256: `db5a217e98330d92214812adef11fe8786272754b7ce569a025e5a8848b17d53`
- Native libraries present for: `arm64-v8a`, `armeabi-v7a`, and `x86_64` (`x86` is not present in this APK).
- Package contents include `libonnxruntime.so`, the LiteRT model manifest and TFLite model assets, the ANVIL-S 540p ONNX model, and the live-switch app code.
- `unzip -t` reports no archive errors.

## Qualification boundary

No Android device was attached during this build. This proves Kotlin/Java/native compilation and APK packaging only. It does not prove Android playback, visible synthesized frames, LiteRT or QNN provider selection, NPU/GPU execution, A/V sync, frame deadlines, thermal behavior, or live preset switching on a device. No GPU was used for this Android build. On the dual-GPU Linux host, PME GPU work remains isolated to the RX 7900 XT; the RX 9070 XT is reserved for desktop use.

This was a local build; no CI workflow or job was changed or dispatched.
