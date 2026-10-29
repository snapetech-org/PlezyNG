# Ubuntu 24.04 local Linux PME bundle — 2026-10-29

This is a local compile and packaging check for the PlezyNG Linux bundle using the PME/Vulkan-enabled mpv artifact built from the motion fork. No CI runner or workflow was used.

## Inputs and build

- App worktree: `codex/android-provider-fallback-20261028`, based at `9d0b6c256b064098ae5de935e7df62ea35c2a937`.
- Local mpv content key: `5756699fd308`; archive `libmpv-linux-5756699fd308-x86_64.tar.zst`, SHA-256 `8230f46af79bdeeda7c8a456b0bdeb2179f5d56401f113886a0974647b8547de`.
- Build environment: task-owned Ubuntu 24.04.4 x86_64 container, Flutter 3.47.1 / Dart 3.13.1, offline Pub cache, and isolated project snapshot. The source checkout and shared Flutter/Pub caches were not modified by the container build.
- Build command: `flutter build linux --debug --no-pub` after `flutter pub get --offline`.
- Build log: `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/linux-flutter-build-ubuntu-local-20261029-retry2.log`.
- The generated app executable SHA-256 is `323b4e96307e396ff40c58b3c0ce9b0a3fc98f70597a455f6d8c1b5149350489`; its highest required glibc symbol is `GLIBC_2.38`.

## Packaging fixes and checks

The fresh build exposed two Linux packaging issues, fixed in this worktree:

1. `linux/CMakeLists.txt` now sets the default relocatable bundle install prefix immediately after `project()` and before Flutter/plugin subprojects initialize GNUInstallDirs. The clean build configured the bundle path consistently instead of retaining `/usr/local` from an earlier subproject configure.
2. `linux/packaging/build-packages.py` now declares the external graphics loaders used by the pinned mpv build: `libvdpau1` and `libvulkan1` for Debian, `libvdpau` and `vulkan-loader` for RPM, and `libvdpau` and `vulkan-icd-loader` for Arch.

The built bundle is 927 MB. `ldd` resolves `libmpv.so.2` to `bundle/lib/libmpv.so.2`; no unresolved entries were reported. `linux/packaging/check-bundle-host-deps.py` passes and derives 22 host graphics/audio dependencies, each declared for Debian, RPM, and Arch. The output is a local debug bundle under `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/plezyng-linux-ubuntu-native-9d0b6c256/build/linux/x64/debug/bundle`. The check log is `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/linux-bundle-ubuntu-local-20261029-native.log`.

## Limits

This build was not launched in a real desktop session and does not qualify visible output, Vulkan inference, motion quality, display cadence, or A/V sync. `adb devices -l` returned no attached Android devices, so Android and Tensor playback were not exercised. The Linux bundler logged SIGSEGVs from its `strip`/`find` pass; the script continued, the resulting bundle linked, and the dependency guard passed, but symbol stripping itself is not verified. The coredump service recorded the SIGSEGV metadata, while its core files were reported inaccessible; the build logs are retained as evidence.
