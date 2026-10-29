# Visualization build and release handoff

This document describes the committed entrypoints. It is not an execution log.
The source-only restriction remains active; every future build/test/package job
must run on compatible private ephemeral JIT, with the existing trust isolation.
Do not dispatch CI or publish releases solely because this handoff exists.

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
| Browser SDK | MilkRust `tools/build-wasm-package.sh` | wasm-bindgen 0.2.120 plus pinned Emscripten 3.1.64 compiler JS/WASM and notices |

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
   qualified. Unknown HLSL, legacy-format and exact `.milk2` behavior stays open;
   this build pass does not resolve missing implementation semantics.
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
