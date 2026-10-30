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
| Linux x64/arm64 | `.github/workflows/build.yml` → `scripts/visualizer/build_runtime.py` → desktop CMake install | Matching architecture private worker, C++11, GL/GLES and runtime `.so` |
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
