# Visualization build and release handoff

This document describes the committed entrypoints. It is not an execution log.
The user has authorized builds for this continuation; do not apply the earlier
source-only restriction. Build/package jobs must run on compatible private
ephemeral JIT, with existing trust isolation. No build or test has run because
the connected GitHub tool exposes no workflow-dispatch action. The CI and build
workflows in this repository require manual dispatch. Do not use public runners
or publish releases solely because this handoff exists.

## Runtime build inputs

`native/visualizer/sources.lock.json` pins MilkRust and its vendored compiler.
Every runtime builder verifies that full revision, uses locked Cargo dependencies,
creates an exact source archive excluding unrelated community collections, and
includes AGPL engine and MIT compiler notices. Rust is pinned to 1.97.0. The
approved private image must provide rustup and native C/C++/archive tools; the
scripts provision the selected Rust toolchain and targets in isolated run folders.
Receipts record source identity and file digests, never a qualification pass.

| Target | Regular entrypoint | Required toolchain / artifact |
| --- | --- | --- |
| Linux x64/arm64 | `.github/workflows/build.yml` → `scripts/visualizer/build_runtime.py` → desktop CMake install | Matching architecture private worker, C++17, glibc 2.34+, pidfd-capable kernel, GL/GLES, runtime `.so` and helper executable |
| Windows x64/arm64 | Same builder before Flutter/CMake | MSVC target tools and `milkrust_native.dll` |
| Android | Workflow pre-stage plus Gradle `stageMilkRustRuntime` before merge tasks | Linux x64 private worker, pinned NDK 29.0.14206865; selected ARMv7/ARM64/x86/x64 JNI libraries |
| macOS/iOS/tvOS | Runner Xcode `Build MilkRust Runtime` phase → `build_apple_runtime.sh` | Selected Xcode SDK/architectures; static archive, strong ABI links, C++/iconv |
| Tizen | `.github/workflows/tizen.yml` → `scripts/tizen/build_milkrust.py` → `package.py build` | Explicit Samsung CMake cross toolchain/sysroot; ARM or x64 runtime plus digest-verified manifest |
| webOS | Normal candidate build → `tools/webos/build_milkrust_runtime.sh` → IPK staging/verifier | Pinned LG 26 ARMv7 softfp NDK with target C/C++/AR and Rust target |
| Browser SDK | MilkRust `tools/build-wasm-package.sh` | wasm-bindgen 0.2.120 plus pinned Emscripten 3.1.64 compiler JS/WASM, `milkrust_texture_decoder.js`, and notices |

Desktop CMake's `PLEZY_VISUALIZER_REQUIRE_MILKRUST` defaults to ON. An explicit
OFF build can omit native presets, but is not a visualization release artifact.
Android/Apple/TV standard paths require their runtime bundle. Receipt reuse is
limited to the same run, source, platform, architectures and verified file hashes.
No builder installs credentials or creates production signing keys.

## PCM dependency promotion

The app's present mpv binary lock still contains old artifacts. Use the pinned
`appMpvBuild` source and ordered PCM patch/Android session bridge described in
`native/visualizer/README.md`. Its private-JIT publication gates must verify the
required native exports before promotion. After real immutable artifacts exist,
use `scripts/set_native_revision.sh` with the actual full mpv-build revision and
repository, reviewing all resulting lock/checksum changes. Do not substitute
source hashes for archive hashes. Tizen and the webOS SoLoud route do not use this
mpv extension, but still need their own SDK and physical audio qualification.

## Verification and pack delivery

1. Build/test the pinned MilkRust native and browser compiler/renderer on private
   JIT. The browser `test:hlsl` corpus exercises typed helpers, loops, arrays,
   matrices, writable globals, entry semantics, blur/noise resources, legacy TGA
   uploads, all eleven sprite blend modes, one-frame sprite loading, classic
   gamma/invert, ordered textured-shape gradients, WebGL context restoration and rejected inputs. It emits
   compiler/driver evidence only, not a visual fidelity certification.
2. Build the app packages using the paths above and the promoted PCM artifacts.
   Verify installed runtime/notices/source, actual PCM, preset import/download,
   seeks, pause/background, context loss, dispose, TV focus and unsupported-input
   diagnostics. Preserve failures and exact artifact/engine/device identities.
3. Run reference/corpus/device comparisons before marking any advertised preset
   qualified. MilkRust source now implements the documented saved `.milk2`
   formulas and sprite fields in its declared native/WebGL profile; pixel parity,
   unsupported HLSL/format cases and platform behavior still require their own
   evidence. A build alone does not establish those results.
4. MilkRust's candidate workflow packages the original CC0 study sources, the
   pinned CC BY 4.0 CaYaDev sources, and separate rights-review-required converted
   candidates. Pending inventories are
   deliberately non-promotable. Resolve rights and attach actual per-preset
   evidence for every required target before creating release entries.
5. Run the keyless catalog preflight. Provision owner-held signing custody and
   protected publisher settings, commit the reviewed public root via
   `configure_catalog_trust.py`, then publish/verify the signed immutable catalog.
   The app's current empty root disables remote refresh. Offline imports and the
   included fixture continue to work independently.

No qualification, rights approval, production key or successful installed build
is asserted by this handoff. See [the current ledger](IMPLEMENTATION_STATUS.md)
for the remaining code/reference work as distinct from external qualification.

The 2026-10-29 continuation also adds shared native legacy-image and renderer
lifetime regression programs under `test/native/visualizer_*_test.cc`; the private
Linux address-sanitizer job builds/runs them. Linux/Windows native CI stages the
runtime before configuring the app runner. MilkRust's candidate job now prepares
55 explicitly CC BY 4.0 CaYaDev presets with immutable provenance, in addition to
the original studies and separately unresolved historical candidates. These
entrypoints have not been executed in this source-only continuation.

The updated core regression sources also cover stereo phase preservation, all
classic waveform modes, bounded custom point inputs/colors, portable thick/dot
geometry, isolated object/point state, shape instances, global memory and motion
vectors sampled from the evaluated warp grid. Run them with the pinned engine's
crate checks. The browser SDK mock suite covers stereo ordering and disconnecting
only its owned analysis branch. These sources were reviewed, not executed.

The numeric compiler continuation adds
`crates/milkrust-hlsl/tests/fixtures/numeric.hlsl` to the engine's browser
integration inputs. Its expected pixel checks matrix orientation, component
multiplication, transpose/rectangular multiplication, writable selectors,
single-evaluation indices and function output conversion. Compile acceptance
alone is insufficient; retain its actual pixel assertion when executing the
private-JIT integration gate. This source-only continuation has not run it.

The same browser gate now includes the authored intrinsic numerical control,
macro-rescan/volume-sampling cases, dimension-only bindings and constant LOD
offsets. Run native compiler rejection/limits tests as well as the GPU probes;
syntax parsing does not exercise either compiler. Native and Emscripten build
inputs include the new vendored numeric/intrinsic headers and implementation
fragments through the existing include directory. Their license/provenance
remains the vendored MIT notice plus local patch inventory.


The current MilkRust pin `11b603d2db38f799d5e83f0a95366bd82ca75d1a` also
contains bounded function-macro stringification with preserved token-boundary
whitespace and escaped string tokens, plus worker-based browser raster decoding.
The WASM package builder stages the decoder worker beside the generated module;
the SDK configures its static URL only when it shares the page origin. The same
pin includes per-file `.milk2` header defaults, default-on saved sprites, all
documented saved blend patterns, and shared CPU-quantized sprite diffuse bytes.
Build this exact source on the required private JIT before promoting artifacts.


The declaration/aggregate continuation additionally wires
`declarations.hlsl`, `identifiers.hlsl` and `aggregates.hlsl` into the same
native/browser compiler controls. Their pixel assertions cover inferred arrays,
scoped constants, writable state, reserved names, row-major reconstruction,
nested struct/array casts, readonly storage and single-evaluation side effects.
The invalid-input suite checks constant overflow/index bounds and readonly
writes. Named texture-offset controls retain their constant-expression check.

The sprite probe includes all eleven saved blend modes and 66 combinations of
source alpha, blend mode and opaque-ARGB key matching. Preserve these pixel
checks when running the private gate; source compilation cannot establish those
results. These authored controls are not captures of the MilkDrop3 reference
renderer.
The native C++ and Emscripten builders already include the new aggregate headers
and lowering fragments through their pinned vendored source directory.


## 2026-10-30 HLSL resource-array source checkpoint

The current engine source lock is MilkRust
`2c51a7882971eb9fe6b2b043b8cfa6627e63cbe2`. It expands bounded global
`Texture1D`/`Texture2D` arrays into named bindings for constant-index supported
resource methods. Keep corpus compiler, native and Emscripten checks on the
required private JIT runners; none has been run for this checkpoint.


## 2026-10-30 legacy sampler-array continuation

The current engine source lock is MilkRust
`3673eca589dd65c7e24c04edaed7eb4faa989c55`. Constant-index global
`sampler`/`sampler2D` arrays now expand to separately named images alongside
`Texture1D`/`Texture2D` arrays. No build, compiler run or renderer check has
been executed for this source increment.


## 2026-10-30 resource-array struct-field continuation

The current MilkRust pin is `d3b3f507bcb40a809d797db03ec55efd3e439bd4`.
Constant-index Texture1D/Texture2D and legacy sampler/sampler2D arrays now
support direct fields on global resource structs, mapping each element to an
instance/field-specific image binding. No build, corpus compiler run or renderer
check has been executed for this path.


## 2026-10-30 numeric arrays and native transitions

The exact engine source lock is now
`8beb98b0c4441a73319ddc62b66437ea8451d3d3`. The browser HLSL gate includes
`arrays.hlsl` (multidimensional copies, row slices, side-effecting indices,
function returns and nested matrix structs) and expanded `aggregates.hlsl`
(integer/Boolean matrix initialization and flattened-field cursor alignment).
Run these pixel controls with the existing native rejection/limit suite; none
has been executed here. The pin also preserves bounded dynamic 1D/2D/3D resource
array support and corrects its mixed inclusive/exclusive token-edit ranges.

The private Linux sanitizer job additionally builds and runs
`test/native/visualizer_preset_transition_test.cc`. Exercise the public load
method with zero/default/ten-second durations on every platform, including
rapid changes, pause, resize and audio-generation reset. MilkRust uses a frozen
last-frame display fade; projectM retains its own live transition. Verify the
Kotlin/JNI and Swift/Objective-C selectors in their respective platform builds.


## 2026-10-30 saved-pattern carried randomness

The current pin also removes invented midpoint/seeded random inputs from saved
blend masks. Both GPU hosts key their shared mask cache by the effective carried
header registers. Process-start omitted registers remain zero, and partial
headers inherit preceding values. This is source integration, not a reference
capture or a passed runtime test.

## 2026-10-30 source pin update

The exact MilkRust source lock is now `2e81e049d3dc996d469304e7cdf3e93d0996dbf5`. It includes the corrected
carried-random `.milk2` mask input, global static HLSL sampler-state lowering with independent U/V/W Wrap/Clamp
modes, reference-source paired-tap blur kernels in native GL/WebGL, and bounded
legacy effect-file sampler_state blocks with independent min/mag/mip filters.
Native/WebGL use 96 shared sampler modes; reflection covers offset sampling,
3D fetch and texture-size intrinsics.
Run compiler, renderer, and reference-image work only on the required private
JIT runners. This source update has not been built or tested.


## 2026-10-30 MilkRust sampler parity handoff

The pinned source is `7d7ed901bb105f9ad23431caa25e9f97e095a1bc`. The WebGL sprite pass now uses MilkRust's
shared min/mag/mip and per-axis Wrap/Clamp/Mirror profile, matching native GL.
On the private JIT runners, build and run compiler/resource regressions, then
capture native and WebGL sprites for point/linear filters, mip settings, each
address mode, color keys, and animated images. No build or capture has run for
this source checkpoint.


## 2026-10-30 saved-sprite clamp-order handoff

The current MilkRust pin is `e0752db79a5b74668c4f1c9303630817ca120dec`. Verify scripted repeat values with
non-default saved multipliers, position and scale values near their clamp
limits, all sprite sampler profiles, and animated assets on the private JIT
runner. Reference-pixel and device qualification remain required. No run was
available for this source-only checkpoint.


## 2026-10-30 final sprite source pin

Build and run MilkRust PR #20 at `ee9a0353b4b968dc02a2e6f475b2699592e099c3` on the private JIT runner. Include
classic `.milk` default-on sprites, `.milk2` absent/zero/one sprite flags,
BOM-prefixed wrappers, scripted repeat multipliers, offset and scale clamp
boundaries, Wrap/Clamp/Mirror, min/mag/mip filters, color keys, animated sprites,
and saved blend fixtures. Then capture reference images; no checks have run for
this pin.


## 2026-10-30 latest MilkRust source pin

The app source lock advances to MilkRust `ee9a0353b4b968dc02a2e6f475b2699592e099c3`, including BOM-aware `.milk2` wrapper detection and explicit `sprite=1` gating for trailing saved sprites. The user has requested private builds; the connector has no workflow-dispatch operation and this repository's CI/build entrypoints are manual. No build/test result is available yet. Use the private JIT runner only.


## 2026-10-30 real-file MilkDrop 3 pin

Build and run MilkRust PR #20 at `ee9a0353b4b968dc02a2e6f475b2699592e099c3` on the private JIT runner. Cover Created/version and URL preambles, duplicate headers, numeric-prefix values, incomplete-marker fallback, BOM-prefixed complete wrappers, and explicit `.milk2` sprite enablement. No build or test is available for this pin; the GitHub connector currently exposes no workflow-dispatch action.


## 2026-10-30 MilkRust mask and sprite source checkpoint

The app's exact MilkRust source lock is `551bb46ffbccbe1c0fa0defd5480b240e9efab54` (ABI v2). Its saved-pair mask control
checks all 30 pattern formulas against the published Lactea 4x2 vertex table;
the sprite regression controls now cover duplicate `.milk2` header flags and
ignore preset-body `sprite` records. Build and run this exact revision on the
private JIT runner when a run can be started; capture native and WebGL reference
images separately. No run is attached to this revision, and pixel parity is not
claimed.


## Current MilkRust pin — saved-mask alpha correction

The app lock now pins MilkRust `ba314ab686586f67c06fed09a8036bba03778938` with ABI v2. Its 65x49 saved-pattern alpha field follows D3D9's clamp-and-truncate-to-byte behavior and is uploaded as R8 in both native GL and WebGL. The source control is unrun. Do not treat the engine pin as a built artifact: the connected GitHub tool exposes no manual workflow-dispatch action, and all builds must use compatible private ephemeral JIT runners.


## 2026-10-30 raw finite MilkDrop 3 header values

MilkRust PR #20 now preserves finite float-range `.milk2` progress and random headers raw, including values outside [0, 1]. The cosine variable blend and scene weights use raw progress; only each saved-mask vertex mix is clamped before D3D9 byte truncation. Parser, carried-state, serialization, render-mask and interpolation regression sources were added. The engine pin is `324aee73cef1b6350df1668c340e4b6b6465ca14` (ABI v2). Builds, test execution, and reference captures remain unrun.


## Current MilkRust pin — MilkDrop host inputs

The source lock pins MilkRust `361a4a0c96408bf63760b914cbc508e4fb0494a3` (ABI v2). It adds standard MilkDrop mouse and clock registers, a shared rising-edge `mouseclick`, and reference-style saved-pair blending for these host values. The added regression sources are unrun. This workspace has no Cargo toolchain or project checkout; the connector reports no Actions run for the engine commit. Use the compatible private JIT runner; the connected GitHub tool does not expose manual workflow dispatch.


## 2026-10-30 local clock and preset timing handoff

Build MilkRust PR #20 at `36f3058f150550cc1691303643489c8f89581300` and the
PlezyNG shared native adapter. Verify that single-preset and both `.milk2`
scopes report `time=0` on first render, increment per frame, and reset when a
new source loads. Verify the native ABI date/time setter on desktop, Android,
Apple, Tizen and webOS, including leap dates and invalid-input rejection. Check
local timezone and daylight-saving changes while rendering. The MilkRust browser SDK supplies the page's local date and time before each frame.
Direct WebAssembly/stateless callers that omit the setter retain zero calendar
fields and preset-relative time. This source checkpoint has no build, test,
browser capture, or device run; use only compatible private JIT runners.
Native hosts can call MilkRustEngine::SetMouseState before rendering; platform
pointer-event wiring is still pending. No build, test, or device run is attached to this
source checkpoint; use only compatible private JIT runners.

## 2026-10-30 Current native pointer-input route

The source lock pins MilkRust `e6da67bed512068086179b11724e656a24f5288b` (ABI v2). Validate inline/fullscreen mouse and touch input on Android, Apple, Linux, and Windows: coordinates remain normalized, coalesced movement deltas are delivered once per rendered frame, quick taps still raise `mouseclick`, and pause/focus loss does not leave a button stuck. The browser SDK validates and coalesces the same input before rendering. Build attempts for `cargo build --locked -p milkrust-native` and `flutter build linux` stopped before compilation because Cargo and Flutter are unavailable in this workspace. Compatible private JIT runners remain required; the latest PR heads have no Actions status or workflow runs, and the GitHub connector has no manual Actions-dispatch operation.

## Desktop helper verification

Build and install `plezy_visualizer_helper` alongside the Linux/Windows app; macOS
uses `Contents/MacOS/plezy_visualizer_helper` from the existing runtime build
phase. Verify the helper architecture, dependent runtime lookup, and macOS nested
signature in the final installed artifact. Linux requires glibc 2.34+ and pidfd
support; missing helper/OS support produces an explicit failure, without local
rendering fallback. projectM's pinned framebuffer API is checked inside the Linux
helper. iOS/tvOS still use local rendering with thread quarantine. Android/Android TV
use the private service below; Tizen/webOS use their packaged helper below.

The `visualizer_render_process_test.cc` source needs no GPU or MilkRust library:
it starts itself as a fault-injecting child. Private Linux/macOS sanitizer jobs
compile and run it; Windows native CMake/CTest enables it with
`PLEZY_BUILD_VISUALIZER_PROCESS_TESTS=ON`. Cover normal frames and pointer/PCM
payloads, reset, projectM selection, two-second deadlines, explicit cancellation,
crash, malformed response, and recovery. Also qualify real shader compile/decode
stalls and playback continuity on each packaged desktop target. A killed helper
cannot guarantee recovery of a wedged device/kernel driver. All new cases remain
unrun in this source checkpoint.

The current engine pin is `c58b53cb8b2c41fefd016df25c0d57a96bd8221b`. The next private compiler/browser
run must include static-state forwarding through nested helpers and the new
clamp/wrap pixel controls, numeric argument side effects, legacy `sampler_state`,
forward prototypes, literal resource-array arguments, recursion/capture failures
and the specialization budget. Existing sampler-helper overloads without custom
state retain the typed path and have a regression source. Compilation and these
controls remain unrun; do not infer passing results from the pin update.

## Android renderer service verification

Build all selected ABIs and both debug/minified Android variants on private JIT.
The manifest must retain the non-exported `:milkrust_visualizer` service and R8
must preserve `MilkRustNativeBridge` JNI names (the existing keep rule covers
`startHelper`). Run `MilkRustRendererServiceTest` on a private emulator/device;
it verifies process separation and restart without requiring the MilkRust/mpv
libraries or a GPU context. The native protocol regression now also checks v2
presentation, a hung native-window equivalent and socket cancellation after FD
reuse. No test/build was executed for this checkpoint.

With produced mpv artifacts, exercise close during bind/setup/compile/capture/
presentation, process death, rapid reopen, background/foreground, surface loss,
rotation, quick clicks and queued controls. A retry may report that retirement
is still pending until Binder confirms death. Check that player audio continues
while killing only the renderer service; verify private preset/texture access
in that process. Measure the bounded capture/present RGBA round trip at 1280x720
and 30 fps before approving Android/TV performance. Device-wide GPU/kernel
faults remain outside process-isolation guarantees.


## MilkRust noise resource checkpoint

Build and qualify MilkRust `aeaf9147f4dce6e1f5b13c182e444a7dc368421b` on compatible private JIT runners. The noise generator now mirrors MilkDrop's physical texture dimensions, quality-specific cubic expansion order and single-level texture setup in native GL and WebGL. Compare rendered samples against the reference; random seeding remains deterministic in MilkRust while the reference seeds from its runtime clock. No compiler, browser, GPU, or pixel result is available for this pin.

## Tizen/webOS helper verification

Rebuild TV bundles: manifest schema v1 is no longer accepted for these targets.
Schema v2 includes `plezy_visualizer_helper`, its digest, protocol version 2 and
`visualizer-host-source.tar.gz` with the host revision/digest. Existing Tizen and
webOS runtime builders compile it through the pinned SDK; packaging stages it
as executable `lib/plezy_visualizer_helper` beside `libmilkrust_native.so`. The
TPK/IPK inspectors check the complete bundle, canonical paths, mode, architecture
and hashes. Source checks passed; no SDK build or package was produced.

On private JIT, run the expanded native process test on Linux plus the Tizen and
webOS package regressions. On Samsung/LG devices, verify native child execution
policy, EGL pbuffer access, runtime lookup, inherited-descriptor closure, preset
file access, startup with the firmware's descriptor limit, cancellation during
compile/decode/capture, player death, close/reopen and continued audio. The
parent never signals a possibly reused PID: socket closure drives helper exit,
and an unreaped child blocks retry. A startup failure reports unavailable/failed
without local rendering fallback. Test pointer input, display fades, seek/track
generations and texture leases against the existing music session. Firmware
policy, performance and device-wide recovery remain qualification gates.

## Apple lifecycle and interrupted-preset recovery gate

The Linux sanitizer job and macOS native job now include
`test/native/visualizer_native_worker_test.cc`; macOS also compiles the
Foundation-only `visualizer_apple_recovery_test.mm` with ARC. These sources cover
lazy graphics startup, healthy pause/resume, blocked capture/drain, bounded
retirement, quarantine admission, original error retention, process interruption,
owner tokens, corruption recovery and bounded history. Flutter's session suite
checks automatic-load refusal and explicit retry through a fresh lease.

On private iOS/tvOS SDK builds and devices, exercise native inactive notifications
before Dart responds, context creation racing backgrounding, safe pause/resume,
close while inactive, foreground retirement, process termination while rendering,
restart restoration, timed cycling to an interrupted preset and explicit Reload.
Confirm music continuity and original-scene access. The implementation cannot
cancel an in-flight mobile driver call or contain a device/kernel fault. None of
these checks has run in this workspace.



## 2026-10-30 MilkRust source pin update

Build the exact locked engine revision `893a04399b5e02db8d201701a72f8c4a3ce61791` (ABI v2). It adds bounded APNG and animated WebP decoding, the Texture2D Gather family and
static Texture1D/Texture2D comparison sampling in the bounded HLSL profile, plus
per-renderer runtime-seeded noise shared by native GL and WebGL. Texture1D comparison
sampling uses the center row and requires a one-row asset for parity. Deterministic
noise remains available to offline tooling. Comparison sampling includes the
implicit-LOD `SampleCmp` path but remains unqualified for pixel parity. The current source lock
still records `source-only-unqualified`; do not promote a runtime receipt or pack from
this pin until the private JIT compiler, native/browser decoder and renderer checks,
reference comparisons, and target-device runs have been completed.

## Integrated shader overload and comparison-binding gate

Use the lock's MilkRust `893a04399b5e02db8d201701a72f8c4a3ce61791` source (ABI v2). Run the
native HLSL/core suites and `tools/smoke-hlsl.mjs` on private JIT. Added controls
cover numeric resource-helper overloads and arities, renamed forward parameters,
same-name overload forwarding, typed recursion rejection, grouped ordinary and
comparison state, reflection of generated texture bindings, comparison array
result widths, Gather component order, comparison-before-filter and single
argument evaluation. Exercise both native compiler and Emscripten delivery.

Also run the Apple lifecycle/journal and shared worker regressions described
above, followed by the platform lifecycle/device matrix. Source checks passed;
none of these compiler/test/renderer checks has run. Current build acceptance
cannot be inferred from source commits or from earlier workflow revisions.


## MilkRust comparison-channel and static-state alias gate

Build the exact lock revision `a0ce0242eef5372501a3a6036569e53fb8ad7239` (ABI v2) on the compatible private
JIT runner. Run the native HLSL/core suites and `tools/smoke-hlsl.mjs`, then
exercise Emscripten delivery. New regression source covers all five
Texture2D GatherCmp channel forms, comparison resource-array result widths,
global `SamplerState` and `SamplerComparisonState` aliases (including
forward chains), unresolved targets, and cross-type aliases. Preserve the
existing Gather order, compare-before-filter, overload, recursion and
single-evaluation checks.

No build or test run exists for this engine pin; the GitHub connector does not
expose workflow dispatch for the private JIT jobs. Reference pixels, native
and browser driver behavior, device recovery and artifact promotion remain
separate acceptance gates.


## MilkRust sampler-state alias follow-up

Build exact lock revision `81593b2657c9de2bd6ea4f1903a9f992a3572800` (ABI v2) on the compatible private JIT
runner. The global alias collector now checks both brace and parenthesis depth,
so `SamplerState` parameters in helper overloads do not collide with global
state names. Run native overload/alias/compiler tests, the browser HLSL harness
and Emscripten delivery. This source has not been compiled or tested; the
connected GitHub Actions tools expose no dispatch for the required private job.

## 2026-10-30 download recovery and adaptive quality source closure

Pack downloads now persist up to eight bounded partial archives (256 MiB total)
with immutable catalog identity and strong ETags. Explicit retry sends Range and
If-Range, checks the exact Content-Range/length/ETag, and restarts cleanly when
identity cannot be confirmed. Startup recovery does no networking. Saved progress,
resume/retry and discard controls are present; checksum, catalog reauthorization,
extraction and atomic activation remain mandatory before selection.

Native desktop workers now have a 1920×1080/60 FPS ceiling and mobile/TV retain
1280×720/30 FPS. A shared 60-frame p90 controller adapts resolution, uses ten-second
recovery hysteresis, and reduces desktop cadence to 30 FPS at minimum scale.
The helper's bounded message envelope now accommodates 1080p RGBA, and Linux's
Flutter notification cadence supports the desktop budget. Shader loading and
paused time do not enter steady-state cost samples.

Source regression cases cover quality reduction/recovery and the expanded IPC
frame bound. No tests or builds were executed. These implementation items are
closed separately from device performance, compiler and recovery validation.


## MilkRust direct resource-struct helper checkpoint

Build exact lock revision `1ab258e889d1932395e22015c383695611b918a5` (ABI v2) on the compatible private JIT. It adds bounded specialization for helper parameters whose structs directly contain resources and whose arguments resolve to global struct instances. Local and dynamic arguments fail closed. Run the Rust compiler/core suite, native HLSL suite, browser HLSL harness and Emscripten delivery. The regression source covers both accepted global and rejected local arguments. No run is attached to this revision; the connected GitHub tools do not expose workflow dispatch. Keep the runtime lock `source-only-unqualified` until those checks and later rendering/device gates have evidence.


## 2026-10-30 latest engine pin

The app lock now points to MilkRust PR #20 revision
`994e09dbec15702b03126011f1dcc21d7461f124` (ABI v2). The source correction gives
standard per-frame `blendmode` the upstream default 0 and 0..4 clamp; the
11-entry static `SpriteBlend` table is an explicit engine extension. No compiler,
build, test or device qualification has run for this revision. Keep the lock
`source-only-unqualified` until compatible private JIT and target checks complete.


## 2026-10-30 latest HLSL resource support pin

PlezyNG now locks MilkRust PR #20 at `d7a646af44dc1fbd8d328bf607eaceaa63a46534` (ABI v2). This source revision adds bounded global resource-only struct aggregate aliases for type-compatible global texture bindings; computed, mixed numeric/resource, local and mismatched forms fail closed. The matching native regression source is present but unrun. Keep `source-only-unqualified` until the compatible private JIT jobs and platform qualification complete.


## MilkRust initialized resource alias shape check

Build exact lock revision `86f48b621737aebfbed05b40869f357ebebe4b6f` (ABI v2) on the compatible private JIT runner. Run the Rust compiler/core suite, native HLSL tests, browser HLSL harness and Emscripten delivery. New source cases cover Texture1D-to-Texture2D aggregate alias rejection despite shared sampler lowering and Texture2D scalar/vector-width mismatch. Preserve failures and keep qualification at source-only until these checks and platform rendering gates pass. No executable validation has been run for this pin.

## 2026-10-30 library authoring and dependency source closure

The library now imports bounded ordinary ZIP folders as local-only copies and
exports a selected preset with its assets, original notices and hash provenance.
It can compose .shape/.wave fragments into a new classic-preset copy without
editing the installed source, and export individual indexed objects with
equations and unknown fields preserved. Object slots are allocated deterministically;
mixed formats, remote includes, oversized sources and exhausted slots fail.

Manifest thumbnails are loaded only from the verified library with explicit
encoded-byte and pixel budgets. Missing previews retain the ordinary library
entry. Shared texture packs use exact version/integrity pins, alias-aware
private render views for either engine, bounded aggregate assets and reconstructed
reference counts. Removal or same-version replacement cannot invalidate another
installed pack's pin. Dependency copies remain shared; disposable render views
count against the library quota. Authorized dependencies are fetched only during
an explicit installation, never while browsing or starting playback.

The publisher validates texture-only catalogs and requires nonempty per-texture
qualification evidence on every existing target. This adds source paths; it does
not fabricate qualification or a production signature. Regression source covers
fragment preservation, unsafe inputs, dependency identities and zero-preset
texture catalogs. No build or test ran. The local workspace became unavailable
during this checkpoint; final source was recovered and reviewed through the
repository connection.


## MilkRust corpus-accounting source pin

Build exact lock revision `ca0a94321aadd3b48a9eed9b266796f5ce9a1c03` (ABI v2) on the compatible private JIT runner. Run the Rust workspace/compiler suite, CLI compatibility-report tests, `npm run test:content-report`, and the full community compatibility report. Confirm every discovered CLI entry is retained, the manifest merge accounts for missing/unlisted preset paths, directory/input/read/decode diagnostics are present, and the generated summary's file accounting is complete or lists each remaining exception. The checked-in generated summary remains historical until this run. No executable validation has been performed for this pin.


## 2026-10-30 nested resource-struct source continuation

MilkRust PR #20 commit 7a83ea328be14c4c9acddb24079ef8ac2658b45a now lowers scalar texture fields nested through plain structs when accessed through a global instance. The compiler preserves leaf dimension/element width, resolves full dotted paths, specializes resource-bearing helpers to global instances, and dispatches literal and side-effect-free dynamic indices for bounded resource arrays nested through those paths. Regression sources cover direct/helper access, static/dynamic array selection, binding reflection and rejected nested aggregate initializers. Function-local arrays, nested aggregate initializers and nested sampler-state propagation remain unsupported. This is source only; compiler, browser, native render and device gates remain pending.

PlezyNG locks MilkRust 7a83ea328be14c4c9acddb24079ef8ac2658b45a. The connected GitHub tool reports no pull-request workflow run for this engine revision and exposes no workflow-dispatch action. Run the MilkRust HLSL compiler suite and browser compiler/pixel harness on a compatible private ephemeral JIT runner, including nested texture access, helper forwarding, and static/dynamic nested-array selection. No build or test result exists for this checkpoint; reference-image parity is not claimed.


## 2026-10-30 immutable local resource-struct alias source continuation

MilkRust PR #20 now includes commit 1cfb07306f0ced0b93f5d8aa13e4d5f55782b103 (ABI v2). A local resource-only struct copy initialized directly from a matching global instance is normalized to that binding before opaque-resource specialization. The rewrite is restricted to direct declarations in a function or shader body and rejects mutation, shadowing, mixed structs, computed/aggregate initializers and uninitialized locals. PlezyNG pins this source revision. No compiler, build, test, browser, render or device run was performed for this checkpoint.


## 2026-10-30 statically indexed local opaque-array source continuation

MilkRust PR #20 now includes commit 467adacec200d0fd5551cf5b5c9dee9d0621f750 (ABI v2). Fully initialized function-body or shader-body opaque arrays of 1–15 entries normalize to matching global resource/sampler bindings when every use has a literal index. Computed/partial initialization, dynamic indices, writes, shadowing and nested-scope declarations remain unsupported. PlezyNG pins this revision. No compiler, build, test, render or device run was performed for this checkpoint.
