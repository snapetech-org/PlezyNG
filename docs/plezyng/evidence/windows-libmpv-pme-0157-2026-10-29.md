# Windows libmpv PME timing patch build — 2026-10-29

## Result

Built the Windows x64 and ARM64 libmpv packages locally with
`0157-desktop-pme-sync-timing.patch` in the Windows mpv patch series. The
patch changes PME phase planning to use mpv's active VO vsync interval and
effective playback speed. Both architecture logs show
`video_filter_vf_plezy_pme.c` compiled into `libmpv-2.dll`.

The build used the pinned mpv 0.41.0 source revision
`41f6a645068483470267271e1d09966ca3b9f413` and the patch inputs from
`mpv-build` commit `a4569a2e68f9e5cc29f4dd4b2105fa25961ab5be`. The later
`4acc605` change only documents the Ubuntu libc++ development packages. Both
architectures produce content key `38f824598751`.

The build ran in a task-local Ubuntu 24.04 Docker container with GCC 13.3,
Clang/LLD 18.1, and libc++ 18. Installing `libc++-18-dev` and
`libc++abi-18-dev` let LLVM's configure step detect and use libc++ instead of
caching a failed linker probe and falling back to libstdc++. The build-note
update is in the `mpv-build` motion branch.

Both package sets passed `scripts/test_build_date.sh`; it found no build clock
in any of the six libmpv archive entries or in each symbols archive. Packing
also verified the PDB/DLL symbol pairing. No CI was used.

## Artifacts

| Artifact | Size | SHA-256 |
| --- | ---: | --- |
| `libmpv-windows-38f824598751-x86_64.zip` | 42,040,297 bytes | `681757447ce30210b77bbac0600c9982d88cf8b834f240e09757a56b2cca0d79` |
| `libmpv-windows-38f824598751-x86_64-symbols.zip` | 83,663,906 bytes | `7e0674f3978e0a7cf9795df09a9d39f263d3062b64b59c29b8b7db5c1b478587` |
| `libmpv-windows-38f824598751-aarch64.zip` | 35,266,154 bytes | `49c856e07a90b2846981ea542c796a59ef821447c6bca6c6456c7c0a19d83089` |
| `libmpv-windows-38f824598751-aarch64-symbols.zip` | 78,082,391 bytes | `049820fd8ae684052d33629240467c74f890bea5f6ad0854e24ffe37bd43ec59` |

The files are retained under
`/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-build-windows-0157-native-20261029/dist/release/`.
Build and package logs are in the same worktree's `build/windows/` directory.

## Local pin candidate and asset availability

The Windows manifest update is committed locally in `mpv-build` as
`36f864900c63dc211f0d8d9977ea81b5841c4e14`; it has not been pushed. Running
`scripts/set_native_revision.sh` against it generated a local PlezyNG lock
preview under
`/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/plezyng-mpv-lock-preview-20261029/`.
The preview updates the shared native pin across 11 files. It points Windows
to key `38f824598751`, Android to the existing AAR key `f9b1be38a527`, and
Linux to the older key `52b991183e5f`.

As checked on 2026-10-29, `snapetech-org/mpv-build` has no
`binaries-windows` or `binaries-android` release, and its `binaries-linux`
release exists with no assets. Apple release assets are present. The nine
Android assets for the current manifest and four Linux assets for key
`52b991183e5f` were staged locally from `edde746/mpv-build` and each SHA-256
matches the manifest. The four new Windows assets are also staged locally.
No release assets were uploaded and the PlezyNG lock remains unchanged.

## Limits

These packages are local build outputs. They have not been published or added
to `mpv-build.lock.json`; the PlezyNG Windows application has not been rebuilt
against them. Windows runtime, display presentation, real-display phase
cadence, visual quality, A/V sync, and sustained playback remain unqualified.
Patch 0157 still does not observe mpv's final per-frame `num_vsyncs` choices or
later A/V-sync drop/repeat corrections.
