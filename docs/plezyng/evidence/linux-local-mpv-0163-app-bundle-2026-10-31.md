# Local Linux MPV 0163 and PlezyNG app bundle build

**Date:** 2026-10-31
**Host:** `kspld0` (`EndeavourOS`, x86_64)
**PlezyNG commit:** `47339dceeef8b5315b21e45b255e9b8e3d6857b19`
**mpv-build commit:** `003f85f3071736353c48932a78c239e04ffb64d5`

This local build was done outside CI. The MPV patch-series consistency check
passed. A CPU-only Ubuntu 24.04 container built MPV 0.41.0 with patches
0159–0163 applied, including source-cadence telemetry and RX 7900 XT Vulkan
compute selection. Vulkan is enabled in libplacebo and mpv (`pl_has_vulkan=1`);
the installed MPV API version is 2.5.0. The local prefix library SHA-256 is
`056bf4b4c45311b9228bd90606fc7e5b135235d5c61757abb23ad2b445aad3a3`.

The new library contains `plezy-pme`, `source-cadence`,
`source-cadence-samples`, `source-cadence-fps`, `phase-timing-source`, and the
`RX 7900 XT` selector strings expected by PlezyNG. The MPV and app builds both
completed successfully.

Flutter rebuilt and installed the Linux debug app using the task-local MPV
prefix. Its `CMakeCache.txt` records `MPV_FOUND=1` and resolves libmpv and its
headers to that prefix. The bundle contains ONNX Runtime 1.27.1, the WebGPU
provider, and `libplezy_motion_engine.so`. The bundled, stripped
`libmpv.so.2.5.0` SHA-256 is
`9a0b360d4aac83a9ab445560ca9841b13166863f21dbe7687c10545dbd5e5fe4`.
`LD_LIBRARY_PATH=bundle/lib ldd` found no unresolved dependencies in either
the app executable or libmpv.

The EndeavourOS host does not provide the Ubuntu runtime SONAMEs for
`libmujs.so.3`, `liblua5.2.so.0`, and `libdisplay-info.so.1`; those three files
were copied from the retained earlier Linux bundle. `bundle-libs.sh` completed
and found `/usr/lib/gio-launch-desktop`. The separate host-dependency ownership
checker did not pass on this host: it uses Debian package ownership records,
which do not identify EndeavourOS packages. The manual loader check above
passed, but this does not validate the Ubuntu release package's declared host
dependencies. The copied files match their retained sources byte for byte:
`libmujs.so.3` SHA-256 `56b64ff0e0fc9ab59a1ab5835a18f1f1232b92f50c6baa6b5fd4828e11c226fb`,
`liblua5.2.so.0` SHA-256 `2a9f81d35d00cfed1f0c1da9473eec5005ee35688412a7706e17f0699d8db78e`,
and `libdisplay-info.so.1` SHA-256
`2b42e2620667c9f693561c80d647669d03fd6531c49dbed7bb163c4190abbca6`.

## GPU assignment and limits

- **Compute:** RX 7900 XT (`0x1002:0x744c`, PCI `0000:15:00.0`,
  `/dev/dri/renderD129`).
- **Desktop and output:** RX 9070 XT (`0x1002:0x7550`, PCI `0000:03:00.0`,
  `/dev/dri/renderD128`). MPV's output adapter remains independently selected.
- No inference or video playback was run with this new bundle. The RX 7900 XT
  was occupied by the existing `llama-server` workload (86% utilization,
  20.47/21.46 GiB VRAM, 110°C junction at the captured snapshot); it was left
  running. The RX 9070 XT remained available to the desktop.

This evidence establishes source compilation, telemetry strings, Vulkan build
support, app linking, and local bundle assembly. It does not establish that the
new bundle selects either adapter at runtime, visible presentation, Neural
frame timing, image quality, subtitles/OSD, A/V sync, or sustained thermal
behavior. PlezyNG's published MPV lock remains unchanged. No CI job was
dispatched.

The PlezyNG bundle is retained at
`/mnt/disks/scratch/plezyng-motion-cadence-20261031/build/linux/x64/debug/bundle`.
The task-local MPV prefix and build log are under
`/mnt/disks/scratch/task-scratch/plezyng-motion-local-mpv-20261031/`.
