# Plezy Motion Engine runtime ABI

`pme_runtime.h` is the stable C boundary used by native playback adapters.
`pme_runtime.cpp` loads ONNX Runtime dynamically and keeps execution-provider
registration, session ownership, and tensor validation out of the mpv filter.
The runtime is compiled against ONNX Runtime C API version 27 or newer. Plugin
and catalog providers require a runtime that exposes API 27. A narrowly scoped
Linux compatibility path requests API 23 only when the provider manifest
explicitly selects built-in MIGraphX; this covers AMD's ROCm 7.2.1 ORT 1.23.2
package. The Windows package uses the stable Windows ML 2.4.89 SDK/runtime,
which ships ONNX Runtime 1.27.1.

The current ABI accepts a fixed-shape model with one float32 input tensor and
one float32 output tensor. The playback adapter owns frame conversion,
provider preference, timing, scheduling, and generated-frame presentation.
Model packs are supplied by `NeuralModelPackService`; the library does not
bundle model weights.

Provider candidates are ordered and are checked against the device that owns
the model output. On Windows, the provider manifest uses the `windows-ml`
marker for certified QNN, OpenVINO, Vitis AI, NvTensorRtRtx, and MIGraphX
providers. PME resolves each short registration name through the Windows ML
execution-provider catalog, prepares it on the asynchronous session worker,
registers its returned library path with ONNX Runtime, and verifies the output
provider/device. Windows ML's bundled DirectML provider is the legacy GPU
compatibility fallback. The self-contained runtime adds about 41 MB and is
staged beside the app executable;
vendor execution providers are acquired from the Windows catalog when the
user enables Neural playback on a compatible Windows 11 24H2-or-later device.
Provider preparation runs on PME's initialization worker and observes filter
shutdown: an in-flight Windows ML acquisition is canceled and drained before
its callback state is released.

On Linux, QNN and OpenVINO plugins use ORT's plugin EP API. The AMD ANVIL
manifest selects the built-in MIGraphX provider: the verified ROCm 7.2.1
`onnxruntime-migraphx` wheel is ORT 1.23.2, and the PME loader requests API 23
only for that explicit built-in provider. The pinned 1080p ANVIL-S and ANVIL-M
models have run on an RX 7900 XT with CPU fallback disabled. After three
warm-ups and 12 timed inferences, ANVIL-S measured 25.73 ms median / 29.49 ms
p95 and ANVIL-M measured 33.59 ms median / 38.09 ms p95. These are
inference-only measurements: ANVIL-M leaves about 3.57 ms within a 24 fps source
interval and exceeds the 30 fps interval before frame preparation, transfers,
reconstruction, or presentation are included. The C++ PME ABI was also run
against ANVIL-S in the ROCm 7.2.1 container with only the RX 7900 XT visible.
With CPU fallback disabled, 3 warm-ups and 12 timed calls measured 28.252 ms
median / 32.697 ms p95 through `pme_runtime_run`; this includes ONNX Runtime
tensor handling and output copy, but not decoded-frame preparation, conversion,
interpolation reconstruction, or presentation. A 540p static export of the same
ANVIL-S weights measured 6.851 ms median / 7.329 ms p95 in the same isolated
ABI probe. The complete filter then ran that 540p model against 1080p24 sources
on the RX 7900 XT: a repeated 4:30 null-VO playback generated 5,207 midpoint
frames from 6,409 source frames. The final sampled pipeline was 22.685 ms, with
19 deadline misses and four temporary governor backoffs across the run. This
qualifies local filter throughput, not visible presentation or A/V sync. `scripts/motion/pme_runtime_probe.cpp` can reproduce the ABI path and
reports the actual provider, session-open time, and latency. Build it with
`-DPME_BUILD_RUNTIME_PROBE=ON`; CPU fallback is disabled by the probe. AMD's newer
ROCm 10.1/ORT 1.29 plugin is available for `gfx1100`, but the pinned ANVIL-S
graph currently lands entirely on CPU through that plugin, so PME does not use
it for this model. CUDA uses
`SessionOptionsAppendExecutionProvider_CUDA` with adapter 0. Windows
DirectML uses ORT's `OrtDmlApi` DML2 high-performance GPU selection, and Vitis
AI can use the built-in `SessionOptionsAppendExecutionProvider_VitisAI` API
where the matching runtime is supplied. Accelerator sessions disable CPU EP
fallback. DirectML also disables memory-pattern allocation and forces
sequential execution, as required by that provider. CPU inference is a separate
last-resort session and must be enabled explicitly.

The explicit Linux `--cpu-only` probe opened the 540p ANVIL-S graph on
`kspls0` through `CPUExecutionProvider` at 317.831 ms median / 343.899 ms p95
after three warm-ups and twelve timed calls. That exceeds a 24/30 fps source
interval, so it validates the diagnostic CPU session only; see the
[CPU probe evidence](../../../docs/plezyng/evidence/linux-cpu-probe-2026-10-28.md).

The optional runtime probe can run the explicit CPU session without loading an
accelerator manifest. Pass `-` for the manifest and add `--cpu-only`; it reports
CPU execution separately from an accelerator session that used its opted-in
CPU fallback:

```sh
plezy_motion_runtime_probe \
  /path/to/libonnxruntime.so \
  - \
  /path/to/anvil-s-540p.onnx \
  CPUExecutionProvider 3 12 --cpu-only
```

Build and stage the local Linux AMD diagnostic with:

```sh
cmake -S shared/cpp/plezy_motion_engine -B build/pme-amd \
  -DCMAKE_INSTALL_PREFIX="$PWD/build/pme-amd/stage" \
  -DPLEZY_ORT_LINUX_VARIANT=amd-migraphx \
  -DPME_BUILD_RUNTIME_PROBE=ON
cmake --build build/pme-amd --target plezy_motion_runtime_probe
cmake --install build/pme-amd --component Runtime
cmake --install build/pme-amd --component DevTools
ROCR_VISIBLE_DEVICES=1 \
LD_LIBRARY_PATH="$PWD/build/pme-amd/stage/lib:/opt/rocm-7.2.1/lib:/opt/rocm-7.2.1/lib/migraphx/lib:/opt/rocm/lib" \
  "$PWD/build/pme-amd/stage/bin/plezy_motion_runtime_probe" \
  "$PWD/build/pme-amd/stage/lib/libonnxruntime.so" \
  "$PWD/build/pme-amd/stage/lib/providers.linux.tsv" \
  /path/to/anvil-s-1080p.onnx MIGraphXExecutionProvider 3 12
```

Set `ROCR_VISIBLE_DEVICES` to the selected host ROCm index only for this
process. On `kspld0`, host index `1` is the RX 7900 XT. The playback
qualification container exposes only that card, so it is index `0` inside the
container; it mounts only `/dev/dri/renderD129` for Vulkan. The diagnostic checks
the visible GPU before it reports the selected provider.

Linux runtime discovery checks `PLEZY_PME_RUNTIME_DIR` before the app bundle.
That directory must contain `libplezy_motion_engine.so`, `libonnxruntime.so`,
and `providers.linux.tsv`, plus any provider plug-ins named by the manifest.
The RX 7900 XT development launcher adds that directory and its optional
`migraphx/lib` subdirectory to `LD_LIBRARY_PATH` before starting PlezyNG.
Additional extracted ROCm library directories can be supplied as a
colon-separated `PLEZY_PME_LIBRARY_PATH`; each configured entry must exist.
The launcher also resolves the RX 7900 XT's Vulkan vendor/device IDs and sets
`PLEZY_PME_WEBGPU_VENDOR_ID` / `PLEZY_PME_WEBGPU_DEVICE_ID`; PME uses those IDs
to select and verify the matching WebGPU adapter without changing MPV's output
renderer.
Intel systems can use the optional `openvino` CMake variant to stage the pinned
OpenVINO Plugin EP 1.8.1 with the default ORT 1.27.1 runtime. It includes the
OpenVINO 2026.4 runtime, TBB libraries, GPU kernel cache, plugin license, and
Intel's third-party notices; the extracted package adds about 158 MB. Its Linux
wheel requires glibc 2.28 or later and supports x86_64 only. Intel GPU/NPU use
still depends on the host's driver, and GPU use requires `libOpenCL.so.1`. The
CMake variant downloads the SHA-256-pinned wheel and needs Python 3 to extract
it. The standalone PME CMake project defaults to the smaller `cpu` runtime.
The Linux Flutter app runner selects the portable `webgpu` variant by default;
pass `-DPLEZY_ORT_LINUX_VARIANT=cpu` for a minimal app bundle or choose another
supported variant explicitly. WebGPU uses the host Vulkan loader and driver,
and neural playback falls back to MPV smoothing if the provider cannot open.

```sh
cmake -S shared/cpp/plezy_motion_engine -B build/pme-openvino \
  -DCMAKE_INSTALL_PREFIX="$PWD/build/pme-openvino/stage" \
  -DPLEZY_ORT_LINUX_VARIANT=openvino \
  -DPME_BUILD_RUNTIME_PROBE=ON
cmake --build build/pme-openvino --target plezy_motion_runtime_probe
cmake --install build/pme-openvino --component Runtime
cmake --install build/pme-openvino --component DevTools
```

AMD, Intel, and NVIDIA Vulkan systems can use the `webgpu` CMake variant. It
stages the SHA-256-pinned ONNX Runtime WebGPU Plugin EP 0.5.0 for x86_64 or
ARM64 with the default ORT 1.27.1 runtime. Dawn uses Vulkan on Linux, so the
host must provide glibc 2.28 or later, `libvulkan.so.1`, and a working GPU
driver; it does not need the ROCm userspace stack. The local dual-GPU host's provider enumeration
reported WebGPU hardware IDs for the RX 7900 XT, RX 9070 XT, and integrated
GPU. A strict no-CPU-fallback PME ABI smoke against the built app bundle
executed 540p ANVIL-S on the RX 7900 XT; three calls measured 24.264 ms median
and 33.261 ms p95. This confirms provider execution, adapter selection, and
bundle loading, but the short probe does not qualify real-time playback or its
frame budget. An earlier probe ran while another workload heavily occupied the
GPU and was left running.

```sh
cmake -S shared/cpp/plezy_motion_engine -B build/pme-webgpu \
  -DCMAKE_INSTALL_PREFIX="$PWD/build/pme-webgpu/stage" \
  -DPLEZY_ORT_LINUX_VARIANT=webgpu \
  -DPME_BUILD_RUNTIME_PROBE=ON
cmake --build build/pme-webgpu --target plezy_motion_runtime_probe
cmake --install build/pme-webgpu --component Runtime
cmake --install build/pme-webgpu --component DevTools
```

On Linux, WebGPU automatically prefers the AMD RX 7900 XT adapter
(`vendor=0x1002`, `device=0x744c`) when it is present. An explicit pair of
`PLEZY_PME_WEBGPU_VENDOR_ID` and `PLEZY_PME_WEBGPU_DEVICE_ID` values overrides
that preference and pins the plugin to the matching physical adapter. PME
checks that ONNX Runtime assigns the model output to the selected adapter.
When the Plezy PME runtime and its matching MPV filter are built together,
playback diagnostics identify the RX 7900 XT inference adapter separately from
the PME Vulkan preprocessing/warping GPU; other GPU labels use the provider's
vendor and reported device type when a model name is unavailable.
MPV's separate output renderer is unchanged, so the RX 9070 XT remains
available for desktop and video presentation. The RX 7900 XT launcher detects
`WebGpuExecutionProvider` in the selected runtime manifest and only then uses
`vulkaninfo` to derive those IDs. If the manifest is outside the executable-
relative paths or `PLEZY_PME_RUNTIME_DIR`, set `PLEZY_PME_USE_WEBGPU=1` when
launching. MIGraphX-only runs do not require the `vulkaninfo` utility. MPV's
PME Vulkan compute filter also prefers the RX 7900 XT when no explicit device
override is set. The display-renderer selection remains independent of both
compute paths.

On Windows, PME probes DXGI for the RX 7900 XT by model name and AMD hardware
ID. When present, its explicitly bound DirectML candidate is promoted ahead of
generic GPU providers; the runtime creates a D3D12 device and compute queue on
that adapter and binds them through ONNX Runtime's DML1 API. If this pinned
route fails, generic GPU candidates are skipped rather than moving inference
to the RX 9070 XT. NPU candidates remain eligible. If the RX 7900 XT is absent,
the provider catalog keeps its normal order and DirectML can use its DML2
high-performance GPU policy.

To build the WebGPU runtime into the Linux Flutter application bundle, generate
Flutter's Linux configuration first, then configure and install the app with the
provider variant selected. The runtime, plugin, provider manifest, and notices
are installed into `bundle/lib`, where `MotionProcessingService` discovers them
beside the executable:

```sh
flutter build linux --debug --config-only
cmake -S linux -B build/pme-webgpu-app -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DFLUTTER_TARGET_PLATFORM=linux-x64 \
  -DPLEZY_ORT_LINUX_VARIANT=webgpu
cmake --build build/pme-webgpu-app --target install --parallel 8
scripts/motion/with_rx7900_motion_gpu.sh \
  "$PWD/build/pme-webgpu-app/bundle/plezy"
```

This launcher isolates ROCm to the RX 7900 XT for the MIGraphX path, and
verifies the WebGPU adapter when that provider is selected. WebGPU and the PME
Vulkan filter also prefer the RX 7900 XT in normal Linux app launches; the
RX 9070 XT remains available to the desktop and MPV output renderer.

For AMD's built-in MIGraphX provider, the Linux `amd-migraphx` CMake variant
stages the matching ORT runtime and provider libraries from the verified ROCm
7.2.1 wheel. The target system must provide ROCm 7.2.1 and MIGraphX runtime
dependencies; the app does not bundle that system stack. To reserve a
particular AMD GPU for a development process, set `ROCR_VISIBLE_DEVICES` only
on that process when launching PlezyNG. By default, the runtime enumerates HIP
devices and selects the RX 7900 XT by its model name and PCI identity, then
passes that HIP ordinal to MIGraphX instead of assuming device `0`. If a PCI
Navi 31 adapter (`0x1002:0x744c`) is present but HIP cannot identify its model
and ordinal, provider setup fails instead of silently moving compute to the
RX 9070 XT. Explicit
`ROCR_VISIBLE_DEVICES`, `HIP_VISIBLE_DEVICES`, or `GPU_DEVICE_ORDINAL` values
remain authoritative; MIGraphX device `0` then means the first device in that
process-visible set. The RX 7900 XT launcher resolves its ROCm UUID and makes
it the process's only visible device for local qualification. MPV's output
renderer stays independently selected in either case.

Build the library with `ONNXRUNTIME_ROOT` pointing at an SDK whose C API is at
least version 27 and `PME_ORT_RUNTIME_LIBRARY` pointing at the runtime to stage.
When the Linux runner has no SDK override, CMake downloads the official ONNX
Runtime 1.27.1 package for Linux x64 or ARM64 and verifies its SHA-256. AMD
packagers can select the reproducible x86_64 AMD bundle with
`-DPLEZY_ORT_LINUX_VARIANT=amd-migraphx`. CMake keeps the v27 SDK headers,
downloads and verifies AMD's ROCm 7.2.1 ORT 1.23.2 wheel, extracts only the ORT
runtime, MIGraphX provider libraries, and notices, then installs a manifest
that selects only built-in MIGraphX. The `openvino` variant keeps the default
ORT 1.27.1 runtime and adds the pinned OpenVINO Plugin EP 1.8.1 wheel, which
declares compatibility with ORT 1.23.0 and later. It stages the provider,
OpenVINO/TBB libraries, GPU cache, plugin license, and third-party notices. The
`webgpu` variant keeps ORT 1.27.1 and stages the pinned WebGPU Plugin EP 0.5.0
plus its MIT license and third-party notices for Linux x86_64 and ARM64; the
host supplies the Vulkan loader and device driver. The OpenVINO and WebGPU
plugin variants need Python 3 at configure time for selective wheel extraction.
The PME API-v23 compatibility path is restricted to MIGraphX. The explicit
`cpu` variant bundles only the official ORT 1.27.1 CPU runtime. CMake installs
the runtime as
`libonnxruntime.so` beside `libplezy_motion_engine.so` on Linux, preserves the
versioned `libonnxruntime.so.*` targets behind its SONAME links, and stages
`libonnxruntime_providers_shared.so` so the runtime and provider-loader symbols
are present in the app bundle. It also stages the matching ORT license and
third-party notices. It can stage provider libraries through
`PME_PROVIDER_LIBRARIES` and their non-ORT dependencies through
`PME_PROVIDER_DEPENDENCY_LIBRARIES`. The platform TSV files list registration
names, required device kinds, and plugin paths or provider markers (`builtin`,
`builtin-migraphx`, `builtin-dml`, `builtin-vitisai`, and `windows-ml`) in
selection order. Relative plugin paths resolve from the manifest's directory.

The Windows app pins and extracts the Windows ML NuGet package during CMake
configuration, then stages its runtime, PME, provider manifest, package license,
and package third-party notices beside the Flutter executable. A pre-extracted
package can be supplied through `PLEZY_WINML_PACKAGE_ROOT` for build workers
that stage dependencies separately. Its catalog-backed vendor providers are downloaded and
updated by Windows ML, subject to device, OS, and driver support. The catalog is available on compatible Windows 11 24H2-or-later devices; an unavailable provider falls through to the next manifest entry. Catalog EPs have vendor-specific terms listed in Microsoft's Windows ML third-party notices. The Android LiteRT and QNN paths are independent of this desktop runtime. The mpv filter
adapter and Windows/Linux patch series load this ABI and publish the provider
that actually ran.
