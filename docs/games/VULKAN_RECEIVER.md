# Android and Wayland native Steam video

The Steam receiver has a native Vulkan presentation path for Pyrowave on Android
and Linux/SteamOS under Wayland. It uses the existing experimental Pyrowave
preference, the existing HDR preference, the retained game workspace, the same
input lease and the existing diagnostics. Conventional H.264/HEVC receivers remain
the compatibility path. X11, Windows and Apple do not use this presenter.

## Pixels and capability negotiation

Compressed Pyrowave packets go to a private decoder worker. The decoder writes
three R16 UNORM images. A fragment shader samples those images directly into the
native window swapchain. The production path does not map decoded pixels, create
a bitmap or upload an RGBA Flutter texture. Both 4:2:0 and 4:4:4 are accepted;
chroma siting and full/limited range come from the bitstream.

HDR10 requires all of the following:

- The user's existing HDR preference permits it.
- A hardware Vulkan 1.3 device supports the required subgroup, synchronization,
  timeline semaphore and R16 image features and can present to the native surface.
- The surface exposes a 10-bit packed RGB format with `HDR10_ST2084` colorspace.
- Android reports an HDR10 display, or Wayland reports the necessary color
  management capabilities and HDR output headroom.
- Steam selects Pyrowave and sends a consistent BT.2020/PQ/BT.2020 frame header.

The native shader preserves PQ values through the R16 planes into the 10-bit
swapchain. SDR does not get relabeled as HDR. Mixed or unnegotiated color metadata
is rejected; the old 8-bit CPU converter cannot accept HDR. The launch request
reports display HDR capability and session negotiation advertises HDR10 only for
the qualified Pyrowave path. Neither request toggles the host display mode.

The stream diagnostics distinguish Vulkan from the older decoder paths and show
HDR10 only after an HDR frame has actually been presented. These facts do not
prove panel calibration, HDR brightness or color correctness on a particular GPU.

## Workspace, input and accessibility

Android uses the existing SurfaceView. On Wayland, a native subsurface sits below
Flutter. A transparent aperture in the existing retained stream view reveals it;
Flutter still draws the menus, loading/error states, diagnostics and controls.
The aperture tracks physical pixel bounds and scale. Parked/offstage views hide
the native plane, and removing the view clears its bounds. The native surface has
an empty input region; keyboard, controller, pointer and accessibility ownership
remain with the existing Flutter workspace.

Conventional video can use the same session's retained texture. The platform
channel reports which presentation path is active, and replays that state on
attachment. Older plugins may omit the optional native-plane methods. The new
HDR option defaults to false in native option parsing and is trailing in the
reviewed IHS structs, preserving source-level initialization defaults.

## Lifetime and failure behavior

The GPU worker owns its Vulkan instance, device, surface, decoder and swapchain.
Pyrowave borrows that device, with creation information retained until decoder
teardown. Its decode submission signals a semaphore before the presentation
submission samples the planes. Each swapchain image has its own presentation
semaphore; a render fence alone is not treated as proof that WSI consumed a signal.

Frames are bounded to the selected request size (at most 3840x2160) and 8 MiB of compressed data. The Linux queue holds
at most four frames. Surface acquisition and frame-fence waits are bounded;
resource destruction still waits for driver ownership to end rather than freeing
in-flight GPU resources. A driver stuck inside Vulkan can therefore still block
teardown. Capability failure, invalid frames, output loss or first-frame timeout
uses the existing bounded codec retry path. No failed or merely queued frame is
acknowledged as displayed. Runtime identity checks reject stale presentation
callbacks from previous connection attempts.

Software Vulkan devices are excluded from direct presentation. The test
container's Mesa 25.2.8/LLVM 20 software decoder crashed inside shader processing
both through this presenter and through upstream Pyrowave's CPU-readback API.
This is an unresolved software-driver/codec qualification failure, not a passing
GPU test. Mesa 24.0.5 lacks the subgroup features required by the pinned codec.
The application should use the conventional receiver on those devices.

## Reproducing checks

The SPIR-V is committed so application builds need no shader compiler. Rebuild
or check it with glslang 15.1.0:

```sh
python3 scripts/games/compile_steam_shaders.py --check
```

The portable native tests include wire-level HDR capability negotiation, opt-in
PQ parsing, mixed-color rejection and rejection by the CPU SDR converter. The
Flutter tests exercise aperture transparency under controls, physical bounds,
offstage hiding and the retained texture compatibility path.

For the actual GPU/WSI integration test, configure the Steam native build with
`PLEZY_STEAM_TESTS=ON`, `PLEZY_STEAM_PYROWAVE=ON` and
`PLEZY_STEAM_WAYLAND_TESTS=ON`. Run `plezy_vulkan_presenter_test` inside a Wayland
session, or use `scripts/games/run_wayland_gpu_test.py <test executable>` with
Weston installed. The helper starts and cleans up only its own private compositor.
The test encodes actual 4:2:0/4:4:4 packets and checks presentation, resize, hiding,
SDR HDR-refusal and teardown. Exit 127 is an explicit missing-device/surface skip,
never successful playback evidence.

## Required live qualification

Android NDK/SDK and full Linux runner builds, real Steam host framing, hardware
GPU decode, HDR panel output, color ramps, GPU validation layers, display changes,
rotation, fractional scaling, multiple panes, suspend/resume, device loss and
sustained latency/power measurements remain release gates. A headless SDR
compositor cannot qualify true HDR. Apple/Windows HDR presentation is not supplied
by this implementation. Internet transport and Cloud/Families permissions are
independent of video capability.
