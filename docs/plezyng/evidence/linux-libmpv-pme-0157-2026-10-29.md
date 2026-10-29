# Linux libmpv PME timing patch build — 2026-10-29

## Result

Built the Linux x86_64 libmpv package locally with
`0157-desktop-pme-sync-timing.patch`. The build log records the patch
application and compilation of `video_filter_vf_plezy_pme.c` into
`libmpv.so.2.5.0`.

The package used mpv 0.41.0 at
`41f6a645068483470267271e1d09966ca3b9f413`, the patch inputs from
`mpv-build` commit `a4569a2e68f9e5cc29f4dd4b2105fa25961ab5be`, and content key
`b9f611ed45f8`. It was built by the repository's local container wrapper with
the pinned Ubuntu 24.04 image
`docker.io/library/ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517`.
No CI was used.

## Artifacts

| Artifact | Size | SHA-256 |
| --- | ---: | --- |
| `libmpv-linux-b9f611ed45f8-x86_64.tar.zst` | 26,142,399 bytes | `9e10fd492e82052227459f4eaef8d079d4de7344cca42472392d8325d2682b86` |
| `libmpv-linux-x86_64-symbols.zip` | 10,736,609 bytes | `5d0a370ede720eea295489f2601f27a934366f344f3c461c68d263499b869190` |

The package files are retained under
`/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-build-windows-0157-native-20261029/dist/release/`.
The build log is
`/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/logs/linux-x86_64-pme-0157-build.log`.

## Integration limits

The Linux artifact group uses one content key for x86_64 and ARM64. Both
available hosts, `kspld0` and `kspls0`, are x86_64. Their Docker runtimes reject
`linux/arm64` with `exec format error`, and no native ARM64 builder is
available. The local `b9f611ed45f8` package is therefore not recorded as the
Linux artifact key or added to `mpv-build.lock.json`; the lock still names the
older Linux `52b991183e5f` package. This build proves compilation and package
creation for Linux x86_64, not a complete Linux artifact set.

The new x86_64 package remains local and unpublished. This work did not rebuild
the PlezyNG Linux application against it or qualify visible presentation,
real-display cadence, visual quality, A/V sync, or sustained playback.
