# Linux local MPV and app bundle build (2026-10-31)

This is a local debug build on `kspld0`, outside CI. It verifies that the PlezyNG Linux app can link and package the locally built PME-enabled MPV. It does not qualify visible playback, timing, or A/V synchronization.

## GPU assignment

- **RX 7900 XT (`0x1002:0x744c`, `gfx1100`)** is the PME inference and Vulkan compute GPU. `scripts/motion/with_rx7900_motion_gpu.sh` resolves the card by identity, limits ROCm visibility to it, and selects it for PME Vulkan/WebGPU compute. It leaves MPV's output-device selection unchanged.
- **RX 9070 XT (`gfx1201`)** remains available to the desktop and display/output path.
- This build compiled GPU support but did not submit inference or play video. The live snapshot afterward showed the 7900 XT at 100% utilization, about 20.47/21.46 GiB VRAM, 109°C junction and 100°C memory under the existing `llama-server` process (PID 1841). That process was preserved; no additional inference was run.

## MPV build

The task-scoped MPV source is pinned to v0.41.0, commit `41f6a645068483470267271e1d09966ca3b9f413`. The separate `mpv-build` clone was based on commit `8a94d7a5d3617e56538a7df6c9f75aa45049c955`; its Linux Vulkan changes enable Vulkan in libplacebo and mpv and add `libvulkan-dev` to the container build prerequisites. Those changes are committed as `505a1144452f44a28c23f5eef7ce9fe3a5dec2c8` and pushed to the existing draft [mpv-build PR #2](https://github.com/snapetech-org/mpv-build/pull/2). PME opens a separate Vulkan compute device; the Linux presentation path keeps its EGL/OpenGL renderer.

The local Docker build completed successfully. `pkg-config --modversion mpv` reports `2.5.0`; the installed library is `libmpv.so.2.5.0`, SHA-256 `5a7ebbf20fbbf24f226772727e5fe5ae63735e4a2c9d9b1bbbbcaeeb96a25bd8`. The library contains the `plezy-pme` filter string, and `pl_has_vulkan` reports `1` for the built libplacebo.

## PlezyNG bundle

The app worktree was at `ac701cca4327d317a0d4628fa62b5d130252a468` when built. Flutter/CMake install completed into:

`/mnt/disks/scratch/plezyng-motion-cadence-20261031/build/linux/x64/debug/bundle`

`CMakeCache.txt` records `MPV_FOUND=1` and resolves `pkgcfg_lib_MPV_mpv` and `MPV_INCLUDEDIR` to the task-local MPV prefix under:

`/mnt/disks/scratch/task-scratch/plezyng-motion-local-mpv-20261031/mpv-build/build/local-libmpv-prefix`

The installed `bundle/lib/libmpv.so.2` contains `plezy-pme` and has SHA-256 `b8523c8094acb7945d6865569e1baf8768eb12c1cc7934b696cf5ad2a3c515c1`. The bundle also contains `libplezy_motion_engine.so`, ONNX Runtime 1.27.1, and `libonnxruntime_providers_webgpu.so`. The app ELF uses `$ORIGIN/lib`; the packaged launcher also prepends that directory to `LD_LIBRARY_PATH`, which resolves libmpv's transitive bundled dependencies. The resulting bundle occupies 955,081,799 bytes.

The first `bundle-libs.sh` pass exposed that this host installs `gio-launch-desktop` at `/usr/lib/gio-launch-desktop`, a path the helper did not search. The helper now checks `/usr/lib`; rerunning it succeeded and copied the helper into `bundle/lib/glib-2.0/gio-launch-desktop`. The corresponding Unreleased changelog entry is included with the source fix.

## Limits and retained outputs

This build proves local native linking and packaging with the Vulkan-enabled PME filter. It does not prove that this exact bundle selected the RX 7900 XT at runtime, that the RX 9070 XT presented its frames, or that cadence, image quality, subtitles, thermals, and A/V sync are correct. No CI job was dispatched.

The PlezyNG worktree, app bundle, MPV build clone, source checkout, and build log are retained on `/mnt/disks/scratch`. No task output was written under `/home/keith/.local`, `/home/keith/.codex`, `/home/keith/.cache`, or `/var/tmp`.
