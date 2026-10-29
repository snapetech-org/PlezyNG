# Linux PME 0158 app-bundle integration — 2026-10-29

This is a local Linux app build and package check. No CI workflow or runner was used.

## Build inputs

- PlezyNG source worktree: `codex/android-provider-fallback-20261028` at `97a7aaf5ef243e833bdeb5719580e0e73c5b197e`.
- Build image: local Ubuntu 24.04 x86_64, Flutter 3.47.1, Dart 3.13.1, OpenJDK 21. The JDK was installed only in the disposable build container to provide JNI headers.
- mpv input: `libmpv-linux-aeb29921a7de-x86_64.tar.zst`, with SHA-256 `816fbd730efcd15765a157acb1d70abdb412103e29de28b5daf45fcc0c25e5bb`. This package contains the PME filter and Vulkan path from patch 0158. Its unstripped `libmpv.so.2.5.0` SHA-256 is `e8ddfc0b04f2886fb1b6842a922d273e0e7c9a6c4aeac2f480ead6e7df29dbb8`.
- Build command: `flutter pub get --offline`, then `flutter build linux --debug --no-pub`. A task-local minimal `mpv.pc` supplied only the public include directory and dynamic `libmpv` link required by PlezyNG's runner.
- Build log: `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/build-plezy-linux-pme-0158-20261029-jdk.log`.

## Bundle checks

- Retained app bundle: `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/plezyng-linux-pme-0158-app-bundle-20261029`.
- Bundle size: 927 MB. App executable SHA-256: `f80b4c06ea8bb6c6a4a933805597156e7c0bbbe6fc4c3f6f0fd16dd66d48c056`; highest required glibc symbol: `GLIBC_2.38`.
- The bundled `libmpv.so.2.5.0` contains the Plezy PME filter and has SHA-256 `026eb00bb61b106804d4f7db8dc72db40a0cc7b4837230bcb598d3f9e3801ef8` after the bundler's strip pass.
- `linux/packaging/bundle-libs.sh` collected runtime libraries. Its final `strip --strip-unneeded` pass reported a segmentation fault, so symbol stripping is not verified; the script completed and the bundle remained loadable.
- `linux/packaging/check-bundle-host-deps.py` passed and confirmed all 22 required host libraries are declared for Debian, RPM, and Arch.
- `ldd` reported no missing dependencies for the app executable, bundled libmpv, `libplezy_motion_engine.so`, or `libonnxruntime.so.1.27.1` in the Ubuntu 24.04 environment.
- Packaging log: `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/package-plezy-linux-pme-0158-20261029-retry.log`.

## Qualification limits

This verifies local app compilation, libmpv linkage, and bundle dependency resolution. The PlezyNG lock and published artifacts were not changed. The bundle has not been launched for playback; this evidence does not qualify GPU inference, visible presentation, real-display cadence, neural image quality, A/V synchronization, or sustained thermal behavior. Android/Tensor device execution remains unqualified.
