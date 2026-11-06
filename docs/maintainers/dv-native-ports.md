# Native FEL ports

This work reuses the pinned FFmpeg splitter, mpv layer pairing and libplacebo
residual reconstruction from the Linux experiment. It does not yet provide
qualified FEL playback on every platform. Output conversion to HDR10/SDR and
native Dolby Vision display signaling are separate capabilities.

## Runtime inclusion in normal builds

The owner directive of 2026-11-05 requires implemented experiments in ordinary
release packages. A persisted Settings switch, off by default, controls playback.
Device qualification describes evidence; it does not gate inclusion or require
a separate application, compiler flag, or manually replaced native library.

Android/Linux/Windows native production patch series have been rebased onto the
exact FEL sources in the mpv-build producer. Its normal AAR also carries matching
FFmpeg headers, preventing the Media3 adapter from mixing header and runtime ABIs.
The ordinary Android playback policy uses both the saved preference and a
successfully installed filter, rather than engine presence, to activate FEL.

Apple bundles `PlezyNGDVRuntime.framework` and its prefixed Aether dependencies.
The app links only the small `shared/apple/DVRuntimeAPI` package at its existing
OS floor, then loads the implementation when Settings requests it on macOS 15 or
iOS/tvOS 18. All three Xcode projects run the mandatory packaging phase; the
`DualLayerDolbyVision` trait is always compiled into that runtime. The app never
asks the user to select a build variant. PiP is unavailable while using this
experimental backend. Compatibility playback stays the default.

`tools/dv-engine/build_apple_runtime.py` pins Swift resolution, owns its APFS
DerivedData/package directories, copies frameworks/resources/notices, and records
provenance. Build prerequisites are Xcode 27, XcodeGen and Git LFS. CI installs the
last two automatically. The Mac runtime probe verifies dynamic loading, API
identity, dual-layer initialization and repeatable close. SDK builds passed for
macOS arm64, iOS and tvOS; these do not qualify FEL pixels or physical DV output.
Linux x64 passed the ordinary producer build, shared-library loading, embedded
OpenGL ES render/readback and six FEL shader vectors. Other architecture builds
and complete release artifact checks remain required before delivery.

The Linux offline converter is built by `build_offline_tools.py` from
`offline.lock.json`. It carries Python, VapourSynth, FFMS2, FelBaker, an HDR/SDR
encoder and their runtime libraries. A clean, read-only Ubuntu container with no
network or system Python completed both real authored-fixture exports. The
native ARM64 build runs separately on `ubuntu-24.04-arm`, without emulation.
Ordinary package installation and final artifact pins are recorded with the
release; source-build success alone is not delivery evidence.

The following standalone builders remain development and diagnostic tools. They
are not prerequisites for a user to enable an included experiment. WebOS/Tizen
native playback has no portable BL/EL compositor yet; those app builds remain in
the release scope and must not advertise unsupported FEL reconstruction.

## Windows build and run

Use Python 3.11+ from a native MSYS2 UCRT64 (x86-64) or CLANGARM64 shell.
The environment must supply Git, Bash, Make, Meson, Ninja, pkg-config, a native
MinGW C/C++ compiler, objdump, cygpath, shaderc, SPIRV-Cross and the mpv/libplacebo
development dependencies. Missing dependencies fail the build. The toolchain
packages are recorded, not claimed to be a reproducible SDK pin.

```sh
python tools/dv-engine/build_windows.py --work-dir C:/dv-work/windows --jobs 4
```

Use a new empty directory. The script verifies source commits and submodules,
applies the pairing/composer failure checks, builds D3D11, runs upstream tests,
and probes the *loaded* libmpv's `plezyng-dv-engine` identity. A failed step stops
packaging. The report still says pixels and physical output are untested.

The ZIP contains the engine, standalone executables, import library/headers,
recursive runtime DLL dependencies, source archives, integration sources,
toolchain notices, provenance and a file-hash manifest. PE architecture checks
cover both DLLs and executables. Keep the ZIP's separately emitted SHA256.
Development packaging is not a release license audit: review the recorded
toolchain runtimes and corresponding-source obligations before distribution.

After extracting to a separate directory on a matching Windows architecture:

```sh
python C:/dv-engine/run_windows.py --target sdr -- C:/media/fel.mkv
python C:/dv-engine/run_windows.py --target hdr10 -- C:/media/fel.mkv
```

`auto` lets the graphics context choose output. Explicit `hdr10` requires a
working HDR output. The qualification launcher uses software decoding and
D3D11, preserves source RPU/EL, and rejects options that override its controlled
rendering path. It validates the bundle before launching. Neither HDR nor SDR
requires a precomputed per-movie LUT; the source's own reconstruction metadata
is still needed.

### App integration

The Windows app already embeds `vo=gpu-next`. Its CMake build now accepts:

```text
-DPLEZYNG_DV_ENGINE_ARCHIVE=C:/dv-work/windows/plezyng-dv-windows-x86_64.zip
-DPLEZYNG_DV_ENGINE_SHA256=<the-64-digit-ZIP-hash>
```

Pass these to the app's Windows CMake configure in a **fresh, separate build
directory** with the normal Flutter-generated files/toolchain. CMake checks the
archive hash, manifest, source pins and binary architecture; a partial override
is an error. The normal build still uses `mpv-build.lock.json`. All validated
runtime DLLs are installed with the app and copied for native contract tests.
Sources, notices and reports accompany an experimental app install.

The archive override above is a diagnostic builder option. Ordinary releases
use the rebased production producer and its locked artifacts; users enable the
included implementation in Settings. Start app qualification with hardware decoding off,
then test each hardware/copy path independently. Record the actual renderer,
both layers, composer execution, seek/flush behavior, subtitles and A/V sync.

## Apple device builds

On a Mac with the required Xcode/Swift SDK and XcodeGen:

```sh
python3 tools/dv-engine/build_adapters.py --component apple \
  --apple-platform all --work-dir build/dv-apple-all --build --test
```

Selections are `macos`, `ios`, `tvos`, or `all`; the default remains `macos`.
iOS/tvOS use generic **device** destinations, separate derived-data directories,
disabled signing and pinned package resolution. No account, provisioning
profile, installation or distribution is performed. A completed SDK build is
recorded separately from playback. If a later SDK fails, earlier completed
results remain in `adapter-report.json`.

Production Apple integration cannot simply change `vo=avfoundation` to
`gpu-next`: the current client passes an `AVSampleBufferDisplayLayer`, whereas
the existing upstream MoltenVK example uses a Metal surface. Surface ownership,
resizing, EDR/HDMI negotiation and PiP need an explicit adapter. The existing
VideoToolbox/Metal research host remains the executable experiment meanwhile.

## Preserve production patches across native ports

```sh
python3 tools/dv-engine/audit_native_ports.py \
  --platform all --work-dir build/dv-native-audit
```

This fetches the production build repository at the application's exact lock
commit and the experimental engine's exact source commits. Independent worktrees
receive the FEL integration followed by each component's ordered common and
platform patches. Android, Apple, Linux and Windows are audited independently.
The first conflicting patch stops that component, preserves its tree for
rebasing, and records the unapplied remainder. Conflicts produce a nonzero exit;
there is no automatic patch skipping or fabricated parity result. Worktrees
are for the patch audit, not complete build staging (submodules are fetched in
the pristine source checkouts). Nothing changes the release pins.

Android specifically shares FFmpeg between libmpv and Media3. The production
bridge currently builds against FFmpeg 8.0.1 headers, while the FEL engine uses
a different FFmpeg commit. A port must align headers, shared-library ABI,
all packaged ABIs, JNI glue and production MediaCodec/surface patches together.
An arbitrary replacement AAR is not enabled by this change.

webOS is not represented as a fictional mpv-build platform. Native HEVC/DV
playback support alone does not expose decoded EL frames or GPU composition to
the client. A model-specific accessible path must be demonstrated before a
portable adapter can be implemented or advertised.

## Checks and limits

Local validation for this change: 52 Python contract tests; all pinned mpv
patch replacement anchors matched; the existing C pairing test passed all 11
cases. Those checks do not compile the Windows engine or the Apple host.
No Windows SDK/MSYS2, Xcode, Android native build or physical output trial was
available in this execution environment. The source-stack network audit has
not been run here. Native compilation, production patch rebasing and device
evidence remain required before enabling these paths for ordinary users.
