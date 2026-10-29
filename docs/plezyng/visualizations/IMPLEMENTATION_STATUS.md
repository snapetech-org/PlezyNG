# Visualizer implementation status

Updated 2026-10-29. Current source: [PlezyNG PR #82](https://github.com/snapetech-org/PlezyNG/pull/82)
and [MilkRust PR #20](https://github.com/snapetech-org/MilkRust/pull/20). The app
pins MilkRust `90c150ee121fd8ba73d80c01b5550b6aee2edf6d`; the exact dependency
contract is in `native/visualizer/sources.lock.json`. The
[original plan](COMPLETION_PLAN.md) remains the completion contract.

**This is implemented source, not a verified working release or universal
compatibility result.** No builds, tests, CI dispatch, pack generation, captures,
benchmarks or device runs were performed for this continuation. Confidence is
moderate for source integration; compiled behavior and device fidelity are unknown.

## Source delivered

| Area | Current implementation | Evidence still required |
| --- | --- | --- |
| Native engine | Rust C ABI, GL/GLES rendering, bounded PCM and RGBA capture, independent warp/composite stages and two saved-preset states | First compile/link, driver runs, reference captures and performance |
| HLSL | Pinned MIT typed legacy compiler, native C++ and Emscripten delivery, macros/functions/structs/arrays/matrices/control flow, bounded errors | Corpus coverage, remaining emitter/environment semantics and reference fidelity |
| Shader resources | Three blur levels, original deterministic 2D/3D noise, mipmaps, sampler state, q/frame/random/texture uniforms | Reference noise/blur/uniform behavior and target limits |
| `.milk2` | Saved wrapper, two independent states, saved progress/direction/randoms and procedural masks for documented names | Exact MilkDrop3 mask/progress semantics and executable extensions |
| Platform hosts | Linux, Windows, Apple, Android/TV, Tizen and webOS host source | SDK builds, installed artifacts, audio ownership and lifecycle/device matrix |
| Runtime packaging | Regular desktop/Android/Apple/TV build paths stage the pinned runtime with corresponding source and notices | Produced artifacts, ABI loading, dependency exports and installation checks |
| Library/UI | Search, notices, favorites, playlists, import, download/cancel/retry/update/remove, offline receipts and controls | Executed user flows, accessibility, TV focus, localization and performance |
| Content | Existing offline CC0 fixture plus 24 new original CC0 studies in two MilkRust collections; historical conversion candidates remain rights-review-required | Archive builds, rights review and per-preset/target qualification before catalog promotion |
| Signed delivery | Ed25519 quorum/expiry/sequence/revocation, public-root configuration, keyless preflight, gated publication | Owner-held keys, reviewed public root, environment provisioning and signed publication |

## Audio and host contracts

Linux, Windows, Apple and Android consume an ordered same-player mpv PCM tap.
Its pinned source and Android session bridge are prepared. **The regular app's
`mpv-build.lock.json` still points to older binaries without that extension.**
The mpv-build source must first produce private-JIT artifacts, then the app's
binary lock/verification metadata must be promoted from their real digests.
Inventing replacement checksums cannot close this dependency. Missing PCM APIs
remain an explicit unavailable capability and preserve normal playback.

Linux uses a worker-owned Mesa EGL/GLES 3 context. Windows requires GL 3.3;
macOS selects CGL 4.1; iOS/tvOS/Android/TV use ES 3. Apple now links static
MilkRust archives using strong ABI references instead of relying on exported
`dlsym` symbols. Runtime bundles include the pinned compiler's MIT notice.
Android Gradle stages every selected ABI before asset/native merging; desktop
CMake rejects a missing runtime by default. Tizen package creation requires the
runtime/provenance bundle; webOS IPK creation and verification already require it.

Tizen binds Samsung decoded packets to the exact player/session. Its current
PCM contract is normal-speed S16LE stereo. webOS has a separate app-owned
SoLoud decoder/output route, a post-mix PCM tap, bounded native queue and GLES
Flutter texture host. It supports known-size MP3/WAV/OGG/FLAC progressive audio
up to 10 MiB. Other music/video/live sources retain LG NDL, which has no PCM tap.
The SoLoud tap observes the master mix, not per-voice isolation. Neither TV path
has been built or physically qualified here.

All hosts keep PCM/pixels out of per-frame Dart method channels, serialize
controls, preserve session leases and suspend hidden/paused rendering. The
in-process worker cannot contain a hung graphics driver; teardown can block.
Compiler budgets are useful input limits, not driver-process isolation.

## Compatibility and content boundaries

The HLSL integration is a legacy pixel-shader profile, not every DirectX language
or resource feature. Unsupported semantics/resources/array bounds fail with
bounded diagnostics. EEL, legacy encodings, external textures and remaining
corpus formats still need complete conformance work. The separate WGSL renderer
retains its own restricted translator. Exact `.milk2` semantics remain code and
reference work: the available upstream snapshot does not contain the saved
pattern renderer, and the independent masks are not evidence of equivalence.

Every imported file remains in the corpus denominator. Parse success, compiler
acceptance and a nonblack frame must not be reported as faithful rendering.
The new original collections are source candidates, not additional published
app downloads. Their builder creates pending inventories for all 13 release
targets. Historical collections retain unresolved redistribution status;
disclaimers never substitute for rights. No qualification report or production
private key was invented.

## Build and release handoff

[BUILD_HANDOFF.md](BUILD_HANDOFF.md) identifies the build entrypoints, artifact
promotion and evidence needed. [CATALOG_RELEASE.md](CATALOG_RELEASE.md) records
public-root provisioning without private keys in source. All executable work
must use compatible private ephemeral JIT runners under `AGENTS.md` and the
existing source-only restriction; no workflow was dispatched for this change.

The remaining work is broader than access to physical hardware: compiler/link
verification, mpv artifact production/promotion, reference semantics, corpus
qualification, rights decisions and production custody/publication are also open.
