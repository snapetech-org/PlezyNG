# Qualcomm QAIRT context pack and Android staging — 2026-10-28

This records full host-side context generation and Android runtime staging for
ANVIL QNN HTP. It establishes manifest integrity and Gradle packaging inputs;
it does not establish inference on a Snapdragon device or visible playback
quality.

## Inputs

- Host: `kspld0`, x86_64 Linux.
- QAIRT SDK: 2.51.200, build `261021095627`, from the locally downloaded
  `v2.51.200.261021.zip` archive (SHA-256
  `c0dbd66d6eb25c5ac2d099f6eebc9a7dfd05ff8d22e96028c475efc4fbbbe2e0`). The
  extracted `sdk.yaml` SHA-256 is
  `d3287e0c0b303cb8d90a8dff77df5acbe60afad7dad9dac9aa73e1bee8e72015`.
- ANVIL source revision:
  `f701fd9b01b9fbb20822637b5d82cac626079e5f`.
- Checkpoint revision:
  `fa97e30f6aabe897bd4f6f82d971ad607f5d61fa`.
- Calibration: 16 evenly spaced consecutive frame pairs from the Blender
  Foundation *Tears of Steel* clip, with 720p and 1080p tensor metadata and
  sample hashes in the manifest.
- The QAIRT host converter used Python 3.12 and a task-local Ubuntu `libunwind`
  dependency extracted under `/var/tmp`; no system-wide compatibility library
  was installed. `TMPDIR` remained writable for QAIRT multiprocessing sockets,
  and the executable-stack adjustment applied only to temporary x86_64 model
  libraries.

## Generated context pack

The complete pack is retained at
`/var/tmp/plezyng-motion-sdk-acquisition-20261028/qualcomm-anvil-contexts-full-20261028`.
It contains 22 of 22 contexts: ANVIL-S and ANVIL-M for 11 SoC mappings, with
720p contexts for V68/V69 and 1080p contexts for V73/V75/V79/V81. The context
files total 100,503,552 bytes. The full manifest SHA-256 is
`5e19899869b87498d42e0688b08fcf235f5afe5a8e48da327c7ca82d1c07d46a`.

A local verifier checked every manifest-listed context's size and SHA-256,
the exact 22 expected context paths, both calibration records, the QAIRT
`sdk.yaml` checksum, and each context's ONNX input hash against the pinned
model files. The earlier interrupted 19-context attempt and its log remain
preserved separately; its stale one-entry manifest was not used for packaging.

## Android staging result

With `QAIRT_SDK_ROOT` set to the extracted QAIRT root and
`PLEZY_ANVIL_CONTEXT_ROOT` set to the complete pack, this command succeeded:

```sh
./gradlew --no-daemon --console=plain :app:stageAndroidAnvilRuntime
```

Gradle accepted the full manifest, copied and re-verified all 22 contexts,
and staged the ARM64 QNN runtime, V68/V69/V73/V75/V79/V81 stub libraries, and
matching Hexagon skeleton assets. The staged manifest hash matched the source
manifest. This is packaging-input validation only.

A full `:app:assembleDebug` attempt reached Flutter compilation and stopped on
Dart errors outside the QAIRT path: missing `nativeVisualizationAudioReady`
accessors in music visualization; missing `state`, `currentPosition`, and
`subtitlePcmCaptureAvailable` members plus a player type mismatch in subtitle
capture; and an unresolved `base64Decode` reference in the Tizen video-hole
plugin. No APK was produced from this first attempt. It predates the fixes in
the current main revision and is retained as a historical record. A subsequent
full APK build passed after resolving those blockers and the Android toolchain
issues; see the [full debug APK evidence](qairt-debug-apk-2026-10-28.md).

## Remaining qualification

No QNN inference was run on a Snapdragon device. Context selection, HTP graph
execution, thermal behavior, playback timing, and generated-frame visual
quality still require target-device qualification. The pack and SDK binaries
remain in task scratch and were not added to the repository.
