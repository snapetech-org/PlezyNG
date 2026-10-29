# Android ANVIL asynchronous failover evidence

**Date:** 2026-10-29
**Host:** `kspld0`
**Source branch:** `codex/android-provider-fallback-20261028`

## Implemented behavior

`MotionProcessingService` now polls Android ANVIL provider metadata and decoded
source-frame progress after attaching the QNN or LiteRT filter. A successful
provider inference ends the watch. An explicit unavailable/CPU provider, or no
successful inference within 45 seconds after source frames begin, triggers
fallback. The watch is bounded at 90 seconds and uses a per-player generation
token so a late result cannot reconfigure a different playback session.

An asynchronous QNN failure retries LiteRT CompiledModel. A LiteRT failure or
inference timeout restores MPV smoothing when that output remains available.

## Local validation

- `flutter test --no-pub test/services/android_anvil_provider_status_test.dart`:
  3 tests passed.
- `dart analyze lib/services/motion_processing_service.dart
  lib/services/android_anvil_provider_status.dart
  test/services/android_anvil_provider_status_test.dart`: no issues found.
- `flutter build apk --debug --no-pub --target-platform=android-arm64`: build
  succeeded locally.
- The APK embeds the source LiteRT manifest byte-for-byte. All eight packaged
  float32 GPU and generic W8A8 JIT NPU model files matched their manifest sizes
  and SHA-256 values.

Retained APK: `/var/tmp/plezyng-motion-sdk-acquisition-20261028/android-provider-fallback-debug.apk`

Size: 589,786,604 bytes
SHA-256: `ccc7c1ddcb44a0fe5fb06016c592b8dcfdf9a236c3a80a4b5d35f19ad6794015`

Local logs are retained in
`/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/`:
`android-anvil-provider-test-resume.log`,
`android-anvil-dart-analyze-resume.log`, and
`android-provider-fallback-build-final.log`.

## Qualification boundary

No Android device was attached (`adb devices -l` returned no devices). The APK
was not installed, so QNN/LiteRT execution, NPU selection, inference latency,
visible smoothing, presentation pacing, A/V synchronization, thermal behavior,
and user-visible failover remain unqualified. The bundled W8A8 models are
generic JIT candidates; this build does not include Google Tensor target-specific
AOT models.

No CI workflow was triggered or queried for this evidence.
