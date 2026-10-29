# Windows and Apple Steam HDR

The opt-in Pyrowave preference and existing HDR preference now control the
Windows and Apple HDR paths. The host must select BT.2020 primaries and matrix,
PQ transfer and the negotiated codec. SDR H.264/HEVC remains the recovery path.
Neither receiver changes the operating system's display mode.

## Windows

The shared Vulkan 1.3 presenter owns a disabled child HWND beneath Flutter's
DirectComposition controls, matching the app's mpv placement. Decoded R16 planes
remain on the GPU and render into a 10-bit ST2084 swapchain. The system Vulkan
loader is loaded only from System32. No driver or SDK download occurs at runtime.

HDR requires both the Vulkan surface format and the current DXGI output's
10-bit BT.2020/PQ mode. The monitor is rechecked during playback; moving to an
ineligible display or losing HDR cancels that attempt and recovers to SDR.
The window is hidden offstage and destroyed on the UI thread after GPU teardown.
Native geometry, first-frame acknowledgement and metrics use the existing
workspace contract. Mouse, keyboard, gamepads, menus and accessibility remain
owned by Flutter. GPU initialization failure retains the Media Foundation path.

The pinned Granite dependency has a scalar frustum fallback for compilers without
its SIMD macros, including MSVC ARM64. Granite's unused DXGI interop is disabled;
Plezy owns the swapchain. No additional CPU instruction baseline is imposed.

## Apple

The Metal decoder configures its output from the first validated color header:
BGRA8 for SDR, RGBA16Half for HDR. HDR conversion uses 10-bit digital offsets and
the BT.2020 matrix, preserving PQ values. The IOSurface is sampled into a native
`CAMetalLayer` with BGR10A2, the ITU-R 2100 PQ color space and EDR enabled. It does
not pass through Flutter's BGRA8 texture. GPU work stays on the serial decoder
worker; controls retain the existing transparent aperture and focus behavior.

HDR requires a compatible Metal Pyrowave GPU, an eligible attached display and
macOS 10.15+ or iOS/iPadOS/tvOS 16+. Older OS versions retain SDR. The app's own
deployment minimum can be higher. Display capability is monitored during the
session; loss cancels HDR and reconnects using a conventional SDR codec. Geometry
uses the actual screen scale, including multi-window movement and offstage hiding.
Teardown stops the display monitor and joins the worker before removing the layer.

## Qualification

Cross-build/linking and source tests do not prove a real HDR display. Test the
current commit on private JIT MSVC x64/ARM64 and Apple SDK builders, then record:

| Case | Required result |
| --- | --- |
| HDR disabled or unsupported | SDR, no HDR metric or incorrect PQ image |
| HDR host, eligible display | 10-bit PQ output; gray ramp and BT.2020 color patches retain precision |
| 4:2:0 and 4:4:4 | Correct chroma siting, limited/full range and neutral gray |
| Monitor move or HDR mode loss | Bounded cancellation and SDR recovery |
| Resize, offstage, minimization | Correct aperture, no leaked plane, no false frame acknowledgement |
| Workspace menus and input | Controls above video; keyboard/controller focus and screen-reader labels retained |
| Repeated connect/close | No use-after-free, retained IOSurfaces, HWNDs, drawables or GPU work |

Apple XCTest includes actual half-float output checks and unexpected color-change
rejection on compatible GPUs. Hardware skips must be reported as skips. Current
Apple SDK/MSVC/Android NDK and live HDR results are not available in this workspace.

Apple's color contract follows
[Using color spaces to display HDR content](https://developer.apple.com/documentation/metal/using-color-spaces-to-display-hdr-content).
Windows mode checks follow
[High dynamic range](https://learn.microsoft.com/en-us/windows/win32/direct3darticles/high-dynamic-range).
