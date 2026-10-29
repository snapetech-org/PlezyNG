# Visualizer implementation status

Updated 2026-10-29. Current source: [PlezyNG PR #82](https://github.com/snapetech-org/PlezyNG/pull/82)
and [MilkRust PR #20](https://github.com/snapetech-org/MilkRust/pull/20). The app
pins MilkRust `b44720c104754cc70e3a3c5d2f31a24c3171cd4a`; the exact dependency
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
| Shader resources | Three blur levels, original 2D/3D noise, mipmaps, sampler state, writable q/frame globals, matrices/hue/original-UV inputs and actual texture dimensions | Reference noise/blur/uniform behavior and target limits |
| `.milk2` | Saved wrapper, two independent states, saved progress/direction/randoms, independent masks, active saved sprite equations and native/WebGL layers/blends | Exact MilkDrop3 mask/progress and sprite-field/filtering semantics |
| Platform hosts | Linux, Windows, Apple, Android/TV, Tizen and webOS host source | SDK builds, installed artifacts, audio ownership and lifecycle/device matrix |
| Runtime packaging | Regular desktop/Android/Apple/TV build paths stage the pinned runtime with corresponding source and notices | Produced artifacts, ABI loading, dependency exports and installation checks |
| Library/UI | Search, notices, favorites, playlists, import, download/cancel/retry/update/remove, offline receipts and controls | Executed user flows, accessibility, TV focus, localization and performance |
| Content | Existing offline CC0 fixture, 24 original CC0 studies and 55 unchanged CC BY 4.0 CaYaDev presets with pinned provenance; historical candidates remain rights-review-required | Archive builds, rights review and per-preset/target qualification before catalog promotion |
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
in-process worker uses bounded teardown with retained shared state and quarantine
admission after a stall. This does not isolate a graphics driver that hangs the
entire process or device. Compiler budgets are input limits, not process isolation.

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

## 2026-10-29 code-completion continuation

- The app pins MilkRust `b44720c104754cc70e3a3c5d2f31a24c3171cd4a`:
  legacy matrices/constants/coordinate helpers and matched blur normalization
  are present in both native GL and WebGL. The same branch now contains 55
  unchanged CaYaDev presets with explicit CC BY 4.0 terms and immutable per-file
  attribution/digests, alongside the 24 original CC0 studies. They remain
  qualification candidates, not newly published catalog downloads.
- All native MilkRust hosts share a bounded CPU decoder for legacy DDS
  (DXT1/3/5 and masked 24/32-bit RGB) and TGA (truecolor/grayscale, raw/RLE and
  orientation). This closes the prior gap where app import allowed those assets
  but a platform codec could not read them. TV stb decoding also accepts GIF's
  first frame. Unsupported DDS arrays/cubes/volumes/modern formats remain explicit.
- Native render workers now capture shared state instead of a host `this`.
  Two-second operation watchdogs report stalled rendering. Teardown disconnects
  bounded PCM/Flutter callbacks before waiting up to 250 ms on the render
  thread; an unfinished GPU/decoder call retains its context and state. A shared
  admission guard prevents new sessions while a worker is quarantined and caps
  concurrent workers at four. Android's potentially blocking surface publication
  holds its own native-window lease. Linux's projectM/MilkRust worker has the same
  lifetime boundary and no renderer call runs under its control mutex.
- This is containment of renderer work, not an OS sandbox or a mechanism for
  killing a stuck GPU driver. A driver that stalls the entire process/device can
  still require an app/device restart. Borrowed PCM/Flutter notification callbacks
  retain their bounded, non-GPU contract. In-flight owned Android publication may
  complete after host teardown against its retained window, never a freed host.
- Private CI source stages required MilkRust runtimes before Linux/Windows native
  target builds and adds decoder/lifetime regression programs with sanitizers.
  No build, tests, CI, archive generation, capture or device run was performed.
  Static diff/JSON/Python-source checks do not replace these execution gates.

- Preset import now decodes UTF-8, BOM-marked UTF-16LE/BE and Windows-1252 before
  checking shader includes. Installed archive bytes stay unchanged. Malformed
  surrogates, undefined code-page bytes and binary controls fail explicitly; both
  input and decoded text remain capped at 2 MiB. Native and browser loaders use
  the same policy, with unrun regression sources in each implementation.
- The updated engine shares writable globals across HLSL helpers, aliases scalar
  and packed q registers, provides original UV/corner-hue/polar entry inputs, and
  binds actual dimensions for named textures. Native dependency lookup strips
  sampler addressing prefixes to load the correct asset. These are source fixes;
  the first compiler/driver runs are still outstanding.

## Final source checkpoint for this continuation

- The source pin above includes bounded Rust DDS/TGA decoding for WebGL, static
  raster header admission before browser decode, reserved aggregate texture
  budgets, and context restoration that rebuilds GPU resources from retained
  preset/assets. CPU equation state survives; unavailable feedback history resets.
- The HLSL compiler now initializes user globals after the host fragment inputs,
  including array/struct defaults and constant integer array bounds. This closes
  illegal uniform-initializer and unbound-custom-global cases; reference corpus
  conformance is still unmeasured.
- `.milk2` honors explicit `sprite=0` with well-formed disabled trailer blocks,
  preserving them on export. Active sprite equations/layers/blends now have bounded native/WebGL source paths; disabled blocks remain inert.
  Independently authored pattern masks still are not exact MilkDrop3 semantics.
- Native DDS row validation avoids multiplication overflow on 32-bit TV targets.
  Regression source covers excessive pitch in addition to color/alpha/orientation.
- Current main at `804a1cc658bba6f2bfb336c0b347b100bf9858ca` is merged, preserving
  its catalog/UI/platform/CI fixes. The decoder formatting conflict was resolved
  while retaining GIF support. No unrelated working checkout was modified.

**Code-completion boundary:** this is not 100% implementation of every community
preset. Exact saved-pair masks and sprite-field/filtering behavior still need
reference conformance; other corpus exceptions
must remain visible through compiler/import/render diagnostics. These are separate
from first builds, mpv binary promotion, physical qualification, report generation
and owner-held signing custody. The latter steps cannot be replaced with source
claims, fabricated checksums, invented rights approvals or an empty trust root.


## Saved sprites and classic rendering continuation

- Saved sprite blocks now have independent persistent EEL scopes, numbered init/frame
  code, final-frame retirement, pack-local texture dependencies, signed transforms,
  color keying and eleven explicit compositing modes. Burning layers enter feedback
  before/after composite; non-burning overlays draw once over the combined display.
  Both GPU backends share geometry and fragment arithmetic. WebGL holds evaluated
  frames while images load. Unknown fields and malformed blocks remain errors.
- Classic video echo, gamma gain, brighten/darken/solarize/invert and clamp/wrap now
  reach both GPU hosts. Feedback includes zoom exponent, stretch, center, animated
  warp, rotation, translation and aspect correction, even without per-pixel code.
  Each grid vertex evaluates once; native/browser dimensions and render FPS reach
  equations. Additive waves/shapes, dots and darken-center are retained.
- Fixed an undefined renderer flag in the engine compatibility-report builder.
  Core and browser regression sources cover the added behavior. No builds/tests,
  CI dispatch, captures, pack generation or physical qualification ran.
- Reference parity for the implemented geometry and audio behavior still requires
  executable conformance checks. This source pin must not be called universal
  community-preset compatibility or a working installed release.

## Stereo, custom state and draw-order closure

- Native and browser rendering now share a bounded stereo PCM analyzer. The
  energy detector preserves anti-phase channels. All nine classic wave modes,
  spectrum selection, alpha modulation, color normalization and stereo strips
  have implementation paths. The browser analysis branch preserves audio graph
  ownership and supplies normalized 44.1 kHz stereo to the shared analyzer.
- Custom waves now receive normalized sample position and left/right value1/value2,
  retain point color/alpha, apply scaling/separation/smoothing and cap sample
  allocation at 512. Pixel-sized dot quads and offset thick strokes work in both
  GPU hosts. Errors and non-finite geometry reach checked frame diagnostics.
- Custom objects retain private frame and point variables independently, restore
  init t1–t8 at the correct boundary, isolate q writes and propagate explicit
  global-memory writes. Shape instances receive instance indices; both solid and
  textured fills retain gradients, coordinate orientation, angular offset and
  aspect. Draw commands interleave fills/outlines before waves and later overlays.
- Motion trails interpolate the evaluated feedback grid and enter previous
  feedback before warping. Pixel equations are not rerun to construct the trails.
  WebGL position-buffer rebinding is explicit between colored draws.
- Saved sprites apply color keys to texels before linear filtering, accumulate
  speed once per frame, and recognize the neutral saved SpriteRot=1 value.
  Non-default rotation controls and exact saved-pair masks remain reference work.
- Regression source covers these paths, including actual browser shader/shape
  probes, but remains unrun. Only source review, whitespace checks and JavaScript
  syntax parsing were performed. No compiler/link, build, test or device result
  is implied by this updated engine pin.
