# Visualizer implementation status

Updated 2026-10-30. Current source: [PlezyNG PR #82](https://github.com/snapetech-org/PlezyNG/pull/82)
and [MilkRust PR #20](https://github.com/snapetech-org/MilkRust/pull/20). The app
pins the current MilkRust PR #20 source revision in `native/visualizer/sources.lock.json`; the exact dependency
contract is in that file. The
[original plan](COMPLETION_PLAN.md) remains the completion contract.

**This is implemented source, not a verified working release or universal
compatibility result.** The user's 2026-10-30 instruction supersedes the earlier
source-only restriction and authorizes private builds. No build or test has run:
MilkRust PR #20 has no Actions run for the current source revision, and PlezyNG's
CI and build workflows require `workflow_dispatch`; the connected GitHub tool
exposes no workflow-dispatch action. Only compatible private ephemeral JIT
runners may be used. Compiled behavior and device fidelity remain unknown.

## Source delivered

| Area | Current implementation | Evidence still required |
| --- | --- | --- |
| Native engine | Rust C ABI, GL/GLES rendering, bounded PCM and RGBA capture, independent warp/composite stages and two saved-preset states | First compile/link, driver runs, reference captures and performance |
| HLSL | Pinned MIT typed legacy compiler with macros/functions/structs, numeric arrays and matrices, bounded 1D/2D/3D resource arrays, direct struct fields, and scalar nested texture fields/arrays resolved through global instances and specialized helpers, including literal and side-effect-free dynamic nested-array indices | Compiler/corpus execution and reference fidelity; function-local and nested resource arrays, nested aggregate initializers, local/dynamic resource-struct arguments, nested sampler-state propagation, complex resource initializers, dynamic/advanced sampler state and resource kinds outside the profile remain explicit failures |
| Shader resources | Three blur levels, original 2D/3D noise, mipmaps, sampler state, writable q/frame globals, matrices/hue/original-UV inputs and actual texture dimensions | Reference noise/blur/uniform behavior and target limits |
| `.milk2` | Saved wrapper, two independent states, all 30 MIT-specified saved-pattern formulas with GPU interpolation over the 64×48 blend mesh, real Created/version and URL preambles preserved, duplicate headers use the last value and numeric fields consume the compatible prefix, incomplete wrappers fall back to classic parsing, trailing sprites only with explicit `sprite=1` (otherwise preserved and inert), saved state carry, five upstream dynamic sprite blend modes (default 0; truncate and clamp each frame), optional 11-entry `SpriteBlend` engine extension and layers, and bounded GIF/APNG/WebP animation | Reference pixel comparison for final compositing and sprite filtering/layer order |
| Browser texture decode | Static PNG/JPEG/BMP/WebP use a disposable Web Worker with same-origin/blob fallback and timeout; animated GIF/APNG/WebP use bounded Rust decoding on the WASM thread, full-frame upload, frame delays and loop selection | Browser CSP integration, codec/GPU execution, animation regressions and browser-process OOM/driver containment |
| Platform hosts | Linux, Windows, Apple, Android/TV, Tizen and webOS host source | SDK builds, installed artifacts, audio ownership and lifecycle/device matrix |
| Preset changes | Every native MilkRust bridge forwards the selected 0–10 second duration to a bounded display fade from the last published frame; zero cuts immediately; audio generation changes clear history | Executed switching, resize/pause and rapid-selection coverage; this is a frozen-frame fade, not a second continuously running old preset |
| Renderer containment | Packaged MilkRust helper on Linux/Windows/macOS/Tizen/webOS and private Android/Android TV service; Linux projectM shares the desktop helper; bounded native IPC, process termination and retry admission | First builds, injected-fault execution, installed helper discovery/signing and device-wide GPU recovery |
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

Linux uses helper-owned Mesa EGL/GLES 3 contexts. Windows requires helper-owned GL 3.3;
macOS selects helper-owned CGL 4.1; iOS/tvOS/Android/TV use ES 3. Apple now links static
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
desktop worker exchanges PCM, controls and bounded RGBA frames with a packaged
helper process. Requests have a two-second deadline; timeout, malformed replies
and disposal terminate that helper without entering graphics teardown. Windows
uses a kill-on-close job and restricted handle inheritance; POSIX uses a dedicated
inherited socket, parent-death monitoring and SIGKILL (Linux uses pidfds). New
sessions are refused while a terminated helper remains alive. Linux requires
glibc 2.34+ and a kernel with pidfd support. There is no in-process desktop fallback.

Android/Android TV now bind a non-exported service in a private app process.
The player owns its mpv PCM lease and transitions; EGL, shader/image work and
ANativeWindow publication run in that service. Socket shutdown and a separate
service Handler terminate it; retry admission remains occupied until Binder
death confirms retirement. Tizen/webOS now use a packaged helper with socket
cancellation and child admission tracking; their parent sends no PID-based
termination signal. iOS/tvOS defer graphics startup until a preset is visible,
drain work on native inactive notifications, and gate context startup/destruction
on foreground state. A persistent journal prevents automatic restoration/cycling
of an interrupted preset; explicit selection/reload may retry after native
admission permits it. Thread teardown remains bounded and quarantined, and
driver calls remain in the app process. A helper does not contain a
device-wide GPU/kernel fault or provide a filesystem/security sandbox. Private
JIT fault tests and installed-device recovery checks remain unrun.

## Compatibility and content boundaries

The HLSL integration is a legacy pixel-shader profile, not every DirectX language
or resource feature. Unsupported semantics/resources/array bounds fail with
bounded diagnostics. EEL, legacy encodings, external textures and remaining
corpus formats still need complete conformance work. The separate WGSL renderer
retains its own restricted translator. MilkRust source implements the published
saved `.milk2` formulas and sprite fields in its declared native/WebGL profile.
Pixel-level parity remains open: the available official snapshot does not
contain the saved-pattern renderer, and source implementation is not a reference
image comparison.

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
must use compatible private ephemeral JIT runners under `AGENTS.md`. The user has since explicitly requested a build. No Action run is attached to
the latest MilkRust revision, and PlezyNG's build workflows require manual
dispatch; the connected GitHub tool exposes no workflow-dispatch action. No
public runner may be used under repository policy.

The remaining work is broader than access to physical hardware: compiler/link
verification, mpv artifact production/promotion, reference-pixel conformance,
corpus qualification, rights decisions and production custody/publication are also open.

## 2026-10-29 code-completion continuation

- At this checkpoint, the app pinned MilkRust `597cdfb74090c983191dca0505adb8878152c07d` with C ABI v2:
  legacy matrices/constants/coordinate helpers and matched blur normalization
  are present in both native GL and WebGL. The same branch now contains 55
  unchanged CaYaDev presets with explicit CC BY 4.0 terms and immutable per-file
  attribution/digests, alongside the 24 original CC0 studies. They remain
  qualification candidates, not newly published catalog downloads.
- All native MilkRust hosts share a bounded CPU decoder for legacy DDS
  (DXT1/3/5 and masked 24/32-bit RGB) and TGA (truecolor/grayscale, raw/RLE and
  orientation). This closes the prior gap where app import allowed those assets
  but a platform codec could not read them. Animated GIF, APNG and WebP frames
  use MilkRust's bounded disposal/timing path; native WebP and PNG assets also
  use the shared Rust decoder. Unsupported DDS arrays/cubes/volumes remain explicit.
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

- The engine pin now includes bounded HLSL function-macro stringification.
  Token-boundary whitespace is retained, quotes/backslashes are escaped, and
  expansion obeys the existing token/depth/byte budgets. The engine's source
  ledger no longer lists stringification as an open compiler item. No native,
  Emscripten, shader-compiler or pixel gate ran for this update.

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
- Classic `.milk` saved sprites remain enabled by default unless `sprite=0`.
  Trailing `.milk2` blocks execute only with explicit `sprite=1`; missing or
  zero flags preserve them as inert source. Active sprite equations/layers and
  upstream `blendmode` uses five modes with dynamic per-frame semantics. The
  optional static `SpriteBlend` table and modes 5–10 are engine extensions. GPU
  interpolation/compositing and sprite filtering still need reference-pixel qualification.
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

## Typed numeric compiler checkpoint, 2026-10-29

The current engine pin adds shared numeric shape/conversion rules, all float/half
matrix shapes with 2–4 rows/columns, row-order constructors, full-component
scalar splats, component multiplication and dimension-compatible linear
algebra. Matrix masks/indexed rows support writes and increments. Function
output arguments preserve indices and copy converted values back without losing
disjoint writes into the same matrix. Typed vector comparisons, logical
operations, ternaries and bitwise complement share the native/browser compiler.

An authored numerical-result shader and rejection cases accompany the change.
JavaScript syntax and whitespace checks passed. Compiler/driver execution is
still unknown; this source checkpoint does not establish universal HLSL or
MilkDrop3 conformance, nor does it promote unqualified catalog entries.

## Operator, intrinsic and macro continuation, 2026-10-29

The current pin also supplies remainder/shift/compound operators, unsigned
literals, cast/conditional precedence, legacy math and matrix component
intrinsics, typed modf/frexp/sincos outputs, finite checks and bit reinterpretation.
Numeric literals retain round-trip precision; identifier and numeric bounds fail
before unsafe copies/conversions. Macro rescanning supports aliases, returned
function macros, empty token pastes and recursion suppression. Volume sampling,
constant LOD offsets and size-only texture discovery reach both compiler builds.
Shapes now admit up to 500 sides within the aggregate scene budget.

The additional source controls check exact numerical colors, texture calls,
preprocessor boundaries and rejected input. No executable gate has run. Known
scope limits remain explicit: a legacy pixel-shader profile, unavailable exact
MilkDrop3 saved-pattern semantics, reference-dependent non-default sprite
controls, unqualified platform/content cells, real mpv artifact promotion and
owner-held signing/publication. Confidence is moderate in source integration;
compiled and rendered behavior remains unknown.


## Declaration, aggregate and classic sprite checkpoint, 2026-10-29

The current pin includes seven further engine source checkpoints:

- HLSL scoped aliases, generic numeric spellings, grouped declarations, inferred
  arrays and positive constant unroll hints.
- Typed lexical constants, including vector/matrix selections, array elements,
  nested fields and component arithmetic; invalid indices and overflow fail.
- GLSL identifier isolation, indexed matrix scalar swizzles and Boolean scalar
  replication, preserving the identity of user values and intrinsic calls.
- Readonly initializer lowering, legacy flattened aggregate initialization and
  scalar/aggregate casts, including arrays inside structs and `(Struct)0`.
  Expansion is bounded; source expressions are evaluated once. Assignment,
  increment and output-argument destinations must be writable.
- Classic sprite alpha/key behavior, legacy byte color quantization, unwrapped
  script rotation, and scripted selector conversion/clamping. A 30-case browser
  source control covers modes 0–4 across alpha and color-key combinations.

Native and browser regression sources accompany the changes. Static whitespace,
JavaScript syntax and JSON checks passed; no compiler, GPU or device gate ran.
Confidence is high in the recorded source identity, moderate in integration,
and unknown in compiled/rendered behavior.

This does **not** close the original universal-compatibility contract. Known code
limits still include integer/Boolean and one-row/one-column matrices, arrays of
arrays, resource-bearing structs and the restricted WGSL path. Exact MD3 saved
masks (including versioned progress rules), non-default
SpriteRot controls, extended sprite alpha and layer/burn interactions remain
reference-dependent. The checked official source still does not contain the
saved-pattern implementation. Physical hardware alone cannot resolve that
missing reference or these remaining language features.


## 2026-10-29 saved sprite blend-table correction

At this intermediate checkpoint, the MilkRust source path followed the
compatible MIT MilkDrop 3 table for all eleven saved sprite blend modes. That
checkpoint used saved `SpriteBlend` default 4; the current source changes the
default to 0 and computes diffuse bytes in shared Rust code. Existing browser
pixel controls cover all modes and 66 alpha/key/mode combinations. They have not
run; builds, pixel references and device evidence remain unverified.


## 2026-10-29 browser texture worker checkpoint

The app pin packages `milkrust_texture_decoder.js` beside the browser WASM
module. The SDK selects the static worker only when it shares the page origin;
direct users can configure a same-origin URL. Browser-rejected static worker
construction falls back to a blob worker when policy permits it. PNG/JPEG/BMP/
static GIF/WebP decoding and decoded-dimension checks run in a disposable
worker; an 8-second timer terminates the decoder and transfers the resulting
ImageBitmap for upload. This bounds renderer-thread waiting but does not isolate
browser-process allocation failures or a wedged graphics driver. The source
change passed whitespace and JavaScript syntax checks only; no build, browser
execution, GPU run or device qualification was performed.


## 2026-10-29 animated GIF and ABI v2 source checkpoint

MilkRust now admits bounded animated GIF assets through a shared Rust decoder.
Native GL and WebGL upload the composed frame sequence and select frames using
sprite-local or preset elapsed time. The app passes encoded GIF bytes through
the ABI v2 entry point; webOS/Tizen packaging validates the same ABI. Runtime
notices now include the GIF/LZW dependency terms, and Plezy's Licenses screen
registers the core notices from an app asset.

This is source integration only. GIF decoding in WASM runs on the calling thread.
Finite GIF loop counts now repeat each cycle before holding the final frame; a
missing loop extension plays once and a zero count loops forever. At this
checkpoint, the app pinned MilkRust `597cdfb74090c983191dca0505adb8878152c07d`
with ABI v2. The matching
engine source also raises both hosts to the 100-name image-cache limit and uses
packed 32-bit blend-vertex data with per-fragment 64×48 triangle interpolation.
Reference compositing, browser CSP/codec behavior, compile/link, GPU, build and
device results remain unknown; runtime artifacts remain unbuilt.


## 2026-10-29 saved blend header correction

The current MilkRust working source parses each `.milk2` file independently:
missing pattern is empty and fails closed, progress defaults to 0.5, direction
to 1 and omitted random values to zero. Header state is not carried from a
previous file. Trailing sprite blocks execute unless `sprite=0`. At the time of
this intermediate checkpoint, the app lock still pointed at
`597cdfb74090c983191dca0505adb8878152c07d`, which did not contain the correction.
The current lock update advances to the corrected source.

No build, test, browser, GPU or device run was performed. Renderer pixel parity,
non-default sprite-field conformance and the other qualification items remain
open.

## 2026-10-29 animated-image import budget correction

The app's import gate now scans PNG chunk headers and rejects APNG before the
file enters an installed pack. GIF admission walks the block stream, validates
frame rectangles and sub-block bounds, caps each animation at 120 frames and
16 Mi decoded canvas pixels, and charges every frame against the pack's 32 Mi
pixel budget. Standalone `.milk`/`.milk2` import now uses the same 2 MiB source
limit as pack validation and the engine; file reads stop at limit plus one and
reject a changed source size. This aligns import-time accounting with MilkRust's
decoder limits and prevents oversized GIFs from appearing as one-frame assets
during installation. Static PNG remains header-admitted; the native codec
still performs the pixel decode checks. Pack validation now reads image and
preset assets through the same byte ceilings, even if a file changes after a
stat or integrity check. No build or test was run.

## 2026-10-29 sprite burn and image admission correction

MilkRust now follows the inspected saved-sprite draw order in both native and
WebGL: primary final-frame feedback draws use MilkDrop's 4:3 correction, display
copies and Milk2's additional final feedback stamp restore normal geometry, and
Milk2 layers 1–4 enter feedback at their ordered scene stages. Layer 0 and
classic layers use the per-frame burn path. Shared Rust code packs diffuse color
bytes before GL submission. MilkDrop 3 layer/burn and pixel parity remain
reference qualification items.

The app import gate now aligns TGA bit-depth admission with the engine, rejects
truncated PNG chunk streams, accepts JPEG `JFIF` aliases, and bounds static WebP
header inspection while rejecting animation. The preset browser copy now
describes the implemented saved-pattern profile instead of the old Fade-only
subset. `git diff --check` passed; no build, test, browser or device run was
performed. The app lock has not yet been advanced to these current engine source
changes, and no produced runtime includes them.

## 2026-10-29 sprite byte-packing and plan-status checkpoint

MilkRust now computes D3D9-compatible sprite diffuse bytes in shared Rust code
and passes the normalized byte values to native GL and WebGL. The fragment
shader no longer quantizes diffuse RGB or alpha independently on each GPU. This
closes the last identified sprite source mismatch; authored GPU controls and
reference-pixel parity remain unrun.

The current engine source also resolves `.milk2` header defaults per file, runs
trailing sprite blocks unless `sprite=0`, implements the 30 documented saved
pattern formulas and ordered sprite layers, and keeps explicit failures for
extensions outside the declared compiler/format profile. The app source lock
pins MilkRust `4b30f62186cdec0c3c8f19c26174d72648816ba4` with C ABI v2. Builds
remain requested but must use private ephemeral JIT runners under `AGENTS.md`.

## 2026-10-29 preset-boundary source correction

The shared native host now folds ASCII case in `.milk`/`.milk2` suffixes, matching
the pack importer and the mixed-case `.MILk` file found in MilkRust's public
corpus. MilkRust's legacy pair detector now looks for an exact `[preset01]`
section line instead of searching arbitrary source text; comment text can no
longer misclassify a single preset. The parser also rejects active or
equation-backed custom shapes/waves beyond MilkDrop's four slots while
preserving inert out-of-range fields. PlezyNG now pins the corresponding
MilkRust commit. These are source changes only; no
workflow, build, test or device job has run.

## 2026-10-29 process header carry integration

MilkRust now captures valid shared `blending_*` and `random_1..5` writes after
ordinary single-preset frame equations, seeds those registers in the next
source's scope, and preserves them when native or WebAssembly preset loading
recreates renderer/equation state. The Rust runtime exposes validated
snapshot/restore for hosts that recreate the runtime itself. Failed frame
evaluation rolls the carried header state back with the other partial runtime
state. Stateful native and WebAssembly import/inspect validation resolves
omitted wrapper fields against that carried state; stateless pack validation
still fails closed without prior history. PlezyNG now pins MilkRust
`150cbf48c3d017978d3f692d31fd7f2eb0634132` in `sources.lock.json`.

This closes the identified source-level carry gap. Compiled behavior and
reference rendering remain unverified; private JIT runner dispatch is not
available in this workspace.


## 2026-10-30 HLSL resource-array source checkpoint

MilkRust now lowers global `Texture1D` and `Texture2D` resource arrays with
literal bounds from 1 through 15 into separately named image bindings. Their
`Sample`, `SampleLevel`, `SampleBias`, `SampleGrad`, `Load`, and
`GetDimensions` accesses require constant decimal indices; image names use
`<resource>_<index>`. Dynamic or grouped declarations, `Texture3D` arrays,
function-local and struct-field arrays, and non-literal bounds fail closed.
PlezyNG now pins MilkRust `2c51a7882971eb9fe6b2b043b8cfa6627e63cbe2` in
`sources.lock.json`.

No builds, tests, compiler executions or renderer qualification were run under
the source-only restriction. The added path remains uncompiled and unqualified.


## 2026-10-30 legacy HLSL sampler-array continuation

MilkRust also lowers global legacy `sampler` and `sampler2D` arrays with
literal bounds from 1 through 15. Constant decimal accesses are expanded to the
same `<resource>_<index>` named image bindings used by Texture1D/Texture2D
arrays, including accesses through legacy `tex*` intrinsics. Dynamic/grouped
arrays, `sampler3D` arrays, and function-local or struct-field arrays remain
fail-closed. PlezyNG now pins MilkRust
`3673eca589dd65c7e24c04edaed7eb4faa989c55` in `sources.lock.json`.

This source update remains uncompiled and untested under the source-only
restriction; private JIT compiler and renderer qualification remain open.


## 2026-10-30 resource-array struct-field continuation

Constant-index resource-array fields now lower for global struct instances in
addition to top-level Texture1D/Texture2D and legacy sampler/sampler2D arrays.
Each instance binds a distinct image per element using
`<object>_<field>_<index>` names. Function-local arrays and nested
resource-bearing structs remain fail-closed. PlezyNG now pins MilkRust
`d3b3f507bcb40a809d797db03ec55efd3e439bd4` in `sources.lock.json`.

This is source-only work. The new compiler path has not been built, tested or
qualified on native/WebGL renderers.


## 2026-10-30 numeric-array and native transition completion

The source lock now pins MilkRust `8beb98b0c4441a73319ddc62b66437ea8451d3d3`,
which includes numeric arrays up to 16 dimensions with a 4096-element storage
limit, canonical ESSL row structs, typed copies/slices/function returns,
multidimensional brace/cast/default initialization, and corrected integer and
Boolean matrix aggregate cursors/defaults. The bounded dynamic resource-array
work is preserved. A follow-up fixes inclusive/exclusive token-edit range types
in that lowering path. Authored compiler and browser pixel controls remain unrun.

Native preset switching now consumes `transitionSeconds` on Linux, Windows,
Apple, Android, Tizen and webOS. MilkRust fades a retained published frame into
the newly running preset using its paused render clock. Rapid changes capture
the last displayed mixture; resizing samples the retained image at normalized
coordinates; a zero duration cuts immediately; audio generation changes clear
history. This does not keep the old preset's equations alive and does not claim
MilkDrop reference soft-cut equivalence. Linux projectM keeps its engine-owned
transition. Shared C++ cases cover blending, pauses, rapid changes, resize,
cancellation and invalid duration/frame data, and are registered in the private
Linux sanitizer job. Only source inspection and `git diff --check` were performed.


## 2026-10-30 saved-pattern carried randomness

The current pin also removes invented midpoint/seeded random inputs from saved
blend masks. Both GPU hosts key their shared mask cache by the effective carried
header registers. Process-start omitted registers remain zero, and partial
headers inherit preceding values. This is source integration, not a reference
capture or a passed runtime test.

## 2026-10-30 current MilkRust source checkpoint

The source lock pins MilkRust `2e81e049d3dc996d469304e7cdf3e93d0996dbf5`, ABI v2. Saved-mask formulas consume
effective carried random registers directly. Global static HLSL sampler states support all eight standard point/linear
Filter combinations and independent U/V/W Wrap/Clamp addressing. Legacy
sampler_state blocks support separate Point/Linear min and mag filtering plus
None/Point/Linear mip filtering through 96 shared native/WebGL sampler modes.
Direct supported tex* calls use the resource aliases; reflection covers offset
sampling, 3D fetch and texture-size intrinsics. Anisotropic, mirror/border and
dynamic state remain outside the profile. Native GL and WebGL now use MilkDrop's paired-tap blur weights,
source-texel offsets, nested range transforms, and first-level edge darkening.
No build, test, pixel comparison, or device qualification was run. Reference
render parity and private-JIT execution remain open.


## 2026-10-30 current MilkRust sampler and sprite profile

The source lock pins MilkRust `7d7ed901bb105f9ad23431caa25e9f97e095a1bc`, ABI v2. Static HLSL and legacy
`sampler_state` paths use independent filter and U/V/W Wrap/Clamp/Mirror
profiles. WebGL sprite sampling now matches native GL for static assets;
animated assets retain linear filtering without mipmaps. This source checkpoint
has not been built, tested, or visually qualified.


## 2026-10-30 saved-sprite behavior checkpoint

The current engine pin is MilkRust `e0752db79a5b74668c4f1c9303630817ca120dec`. Sprite repeat multipliers and
position/scale offsets now follow the pinned behavior source's clamp order.
WebGL sprite sampling also uses the shared filter and address profile. The
corrections and existing source assertions remain unexecuted; pixel parity is
still open.


## 2026-10-30 current sprite source contract

The exact MilkRust source lock is `60b65d0d4ef1cea5130843628880d9155e085097`, ABI v2. Saved-sprite equation
clamps, offsets and repeat multiplication now match the recorded behavior
source, and the sprite implementation documentation matches the shared native
and WebGL sampler profile. The changes have not been built, run, or reference
compared.


## 2026-10-30 MilkDrop 3 saved-sprite flag correction

MilkRust PR #20 now pins `ee9a0353b4b968dc02a2e6f475b2699592e099c3`. Classic `.milk` saved sprites remain default-on, while a trailing `.milk2` sprite block executes only when the wrapper header explicitly contains `sprite=1`; absent or zero flags preserve the block without executing it. Wrapper detection also handles a BOM before the first marker. The prior source-only restriction has been superseded by the user's build instruction, but no build or test has run. The connected GitHub tool exposes no workflow-dispatch operation, and PlezyNG's CI/build workflows are manual; the required private JIT run remains outstanding.


## 2026-10-30 real-file MilkDrop 3 parsing correction

The source lock now pins MilkRust `ee9a0353b4b968dc02a2e6f475b2699592e099c3`. Real `.milk2` Created/version and URL preambles are accepted and preserved; duplicate headers and numeric prefixes follow the compatible loader behavior. Incomplete marker sets fall back to ordinary preset parsing, and `.milk2` sprites remain inert unless `sprite=1`. No private JIT build or test has run for this pin; the connected GitHub tool exposes no workflow-dispatch action.


## 2026-10-30 saved-mask controls and sprite header gate

The app lock now pins MilkRust `551bb46ffbccbe1c0fa0defd5480b240e9efab54` (ABI v2). The shared saved-mask
generator is checked against the published Lactea 4x2 `(a,c)` table for all
30 patterns, including direction-sensitive variants. MilkRust also aligns the
`.milk2` sprite enable gate with last-value-wins header parsing and ignores
sprite keys inside the two preset bodies; classic `.milk` keeps its existing
first-value/default-on behavior. These regression sources have not run. This
adds source checks only; official-renderer pixel comparison remains open.


## 2026-10-30 MilkDrop saved-mask alpha correction

MilkRust PR #20 now pins `ba314ab686586f67c06fed09a8036bba03778938`, ABI v2. Its saved `.milk2` masks now clamp each vertex mix, truncate to the reference D3D9 8-bit alpha, and upload the same 65x49 R8 field in native GL and WebGL before triangle interpolation. This replaces the earlier full-precision packed field. Regression source covers the byte count and truncation endpoints; it has not run. The latest MilkRust commit has no attached Actions run. PlezyNG's build and CI workflows still require manual dispatch, and the connected GitHub tool exposes no dispatch action. Builds must remain on the required private JIT runners.


## 2026-10-30 raw finite MilkDrop 3 header values

MilkRust PR #20 now preserves finite float-range `.milk2` progress and random headers raw, including values outside [0, 1]. The cosine variable blend and scene weights use raw progress; only each saved-mask vertex mix is clamped before D3D9 byte truncation. Parser, carried-state, serialization, render-mask and interpolation regression sources were added. The engine pin is `324aee73cef1b6350df1668c340e4b6b6465ca14` (ABI v2). Builds, test execution, and reference captures remain unrun.


## 2026-10-30 MilkDrop host input blending

MilkRust PR #20 now pins `361a4a0c96408bf63760b914cbc508e4fb0494a3` (ABI v2). The engine binds standard `mousex`, `mousey`, `mousedown`, and per-runtime rising-edge `mouseclick` variables, along with frame-clock-derived `year` through `totalseconds`. Saved-pair rendering cosine-mixes mouse positions and clock registers and snaps buttons at the reference threshold. Source regressions cover binding, click edges, mixing and snapping; no build or test has run.


## 2026-10-30 MilkRust per-preset and host clock source checkpoint

MilkRust now anchors EEL `time`, frame count and saved-sprite playback at the
source load. Both halves of one `.milk2` begin at the same zero point and keep
separate equation state. Its native ABI accepts validated local calendar and
wall-clock registers. PlezyNG's shared native adapter now refreshes those
registers from the device's local clock before every render and capture. The
engine lock pins MilkRust `36f3058f150550cc1691303643489c8f89581300`, ABI v2.
Regression sources cover preset-clock reset and clock-value binding. No private
build, test, renderer capture or device run has executed for this checkpoint;
the GitHub connector exposes no manual workflow-dispatch operation, and the
private JIT runner requirement remains in force.


## 2026-10-30 MilkRust browser local clock injection

MilkRust now exposes validated local clock fields through its WebAssembly API. The browser SDK supplies the page's local calendar and wall-clock values before each frame, matching the native adapter's host input. Direct WebAssembly callers still choose whether to call the setter. PlezyNG pins MilkRust `039725b4bfa0deee92d7b7364c953dbdfc4851e1` (ABI v2). This source checkpoint has no build, test, browser capture, or device run; use only the compatible private JIT runners.


## 2026-10-30 MilkRust browser clock and native pointer inputs

The app source lock now pins MilkRust `ee0d836a118615fa58eb9125d7b8b2fc23014b24` (ABI v2), which adds validated WebAssembly host-clock injection for the browser SDK and a native mouse-input setter. The shared C++ adapter loads and exposes normalized pointer state for native platform hosts. No platform view currently supplies pointer events to that setter; that wiring remains a source task. No build, test, browser capture, or device run is attached.

## 2026-10-30 MilkRust native pointer route

PlezyNG now routes inline and fullscreen Flutter mouse/touch events through Android, Apple, Linux, and Windows native hosts to MilkRust ABI v2. Event deltas are coalesced and accumulated across the UI and native queues, then consumed once by the next rendered frame. A button-down edge is latched for one frame, preserving taps shorter than the coalescing interval, and pause clears held or pending input. The MilkRust browser SDK also validates/clamps pointer state, accumulates deltas, and preserves short clicks until a render. A malformed Dart handler token found during review was corrected. The source lock pins MilkRust `e6da67bed512068086179b11724e656a24f5288b`. Local `cargo build --locked -p milkrust-native` and `flutter build linux` attempts stopped before compilation because the toolchains are unavailable. Native build, input regressions, and device checks remain unrun; source delivery is not input qualification.

## 2026-10-30 desktop process isolation

The native backend interface separates local mobile/TV rendering from disposable
desktop helpers. Both Linux engines, Windows MilkRust and macOS MilkRust use the
shared protocol: versioned little-endian headers, matching request IDs, bounded
paths/PCM/frame sizes and finite numeric inputs. Partial frames never publish.
Clock, generation, pointer state, pause and preset-transition behavior remain
connected; pending clicks/deltas are consumed only when a frame is rendered.
CMake installs the Linux/Windows executable beside the app. Xcode builds the
macOS helper into Contents/MacOS and signs it with the enclosing build identity.

Regression sources inject crashes, hangs, oversized/truncated replies, wrong IDs,
wrong frame lengths and malformed acknowledgements; they cover cancellation,
recovery, chunked PCM and both backend handshakes. Linux/macOS sanitizer and
Windows native CI entrypoints include them. Whitespace and shell parsing were
checked; no compilation, test, workflow or signing operation ran for this change.
Source review gives moderate implementation confidence; runtime recovery is unknown.

## 2026-10-30 static shader-state forwarding

The engine pin is `c58b53cb8b2c41fefd016df25c0d57a96bd8221b`. Initialized sampler state now remains
attached to its actual texture through bounded helper specialization, including
nested calls and legacy `sampler_state` blocks. Numeric arguments remain ordinary
single-evaluation inputs. Capture, recursion, ambiguous overloads and dynamic state
escape produce explicit diagnostics; the existing typed helper path is preserved
when no initialized state is present. A changing sampler-declaration cursor is
now mutable, fixing a source-level Rust compile error. Native regressions and
browser clamp/wrap pixel controls are authored and unrun. Full profile limits
remain in MilkRust's `docs/HLSL_COMPATIBILITY.md`; no universal HLSL or fidelity
claim follows from this pin.

## 2026-10-30 Android renderer service

The shared transport client is now separate from desktop spawning. Protocol v2
negotiates optional surface presentation and bounds both captured and presented
RGBA frames. Android's one-time Messenger handshake passes a socket and Surface;
per-frame PCM/controls/pixels remain native socket traffic, outside Dart/Binder.
The private service runs setup off its main Handler and enforces a five-second
startup deadline. Each native request retains a two-second deadline. No renderer
executes in the player process and there is no local fallback. This is process
isolation, not a filesystem sandbox or protection against a device-wide fault.

The parent queues startup controls, preserves short pointer clicks, retains the
mpv session lease, and keeps a retiring service's admission lease until Binder
death. Native socket cancellation holds a duplicate FD so Java FD reuse cannot
target another connection. Surface publication and its potentially blocking
lock/post now execute in the service after the player's display transition.
This adds a bounded RGBA round trip; device bandwidth and performance need
measurement. Native test sources cover presentation capability, payload bounds,
hung publication, cancellation and FD reuse. An Android instrumentation source
checks manifest separation, stop-before-start, malformed startup and rebinding
without loading GL/mpv. None has run; compiled/runtime confidence remains unknown.


## 2026-10-30 MilkRust noise resource checkpoint

The source lock now pins MilkRust `aeaf9147f4dce6e1f5b13c182e444a7dc368421b` (ABI v2). Its built-in 2D/3D noise textures now use MilkDrop's physical dimensions, quality-specific cubic expansion in the same axis order, packed channel generation, and a single mip level in native GL and WebGL. The source keeps deterministic fixed seeds rather than the reference's runtime-clock reseeding, so exact noise pixels remain unqualified. No build, renderer execution, or reference capture was run for this checkpoint.

## 2026-10-30 Tizen/webOS renderer helpers

Both TV hosts now send controls, PCM and bounded RGBA frames through protocol v2
to a packaged `lib/plezy_visualizer_helper`. EGL/GLES, MilkRust loading, shader
compilation and image decoding execute there. The parent retains the existing
Samsung/SoLoud audio binding and Flutter pixel leases. The helper monitors socket
closure independently of rendering and exits without graphics teardown; the
parent refuses retries while an old child remains unreaped. This transport does
not require glibc 2.34 or pidfds and never signals a PID from the player. Child
startup closes inherited nonstandard descriptors and sets parent-death SIGKILL.
Both hosts now also handle normalized pointer controls and latched quick clicks.

TV runtime builders compile the helper with the selected SDK and produce its
corresponding PlezyNG source archive. TV manifest schema v2 requires protocol v2,
engine/helper/source/notices digests and host source revision. TPK/IPK staging
and inspection require the helper at its canonical executable location and
reject incomplete, altered or wrong-architecture bundles. Linux fault-test
source covers the older-kernel transport; package regression sources cover the
new artifact requirements. Source parsing/whitespace checks passed. SDK builds,
fault tests, firmware execution policy, installed textures and playback
continuity remain unverified. iOS/tvOS still need a qualified platform recovery
policy; no helper promises recovery from a device-wide driver/kernel fault.


## 2026-10-30 bounded APNG and WebP image paths

MilkRust PR #20 now decodes APNG and animated WebP through bounded shared Rust
paths. Native hosts pass encoded PNG/WebP to ABI v2; native static PNG/WebP use
the same decoder. WebGL keeps static PNG/WebP in its disposable browser worker
and decodes animated frames in WASM. The app import gate admits APNG/WebP only
after frame-count, canvas-dimension, and aggregate-pixel checks. PNG frame
compositing handles source/over blend, disposal, poster frames and play counts;
WebP frames retain disposal, duration and finite/infinite loops. Third-party
notices cover the added decoder crates, and the workspace Rust floor is now
1.80.1.

Source-only implementation is committed. The new native/WASM decoders, app
import route, malformed-image behavior, frame upload and reference pixels have
not been built or run. This does not qualify visuals or driver recovery.

## 2026-10-30 Apple lifecycle and interrupted-preset recovery

The shared native worker now creates its backend only after a preset is selected
and rendering is resumed. Its bounded pause operation waits for pending work and
a backend drain, records timeout as failure, preserves earlier failure reasons,
and reports whether teardown actually retired the worker. Android forwards this
pause to its isolated renderer; local GL hosts finish pending commands on the
owning worker. PCM loops recheck pause/stop before submitting each block.

iOS/tvOS subscribe directly to UIKit inactive/active notifications. Startup waits
for foreground or cancellation, and graphics destruction waits for foreground
on the retained worker. Before GPU startup/resume the host atomically writes and
flushes an owner-tagged recovery record. An interrupted process or failed drain
blocks automatic restore and timed selection of that path; explicit selection
and Reload may retry. A healthy drain after a rendered frame clears the block.
Stale host acknowledgements cannot clear a newer host's record. Records and
failure history are bounded; unreadable state blocks automatic loading.

This is a mobile recovery policy, not out-of-process rendering. A driver call
already in flight may still stall or terminate the app. Context cleanup deferred
while inactive keeps native admission occupied until it retires. Native worker,
thread-retirement, Foundation journal and Dart retry regression sources are
registered for private JIT. They have not been compiled or executed. Confidence:
moderate in source integration; SDK behavior and device recovery remain unknown.



## 2026-10-30 earlier MilkRust source pin — APNG/WebP and noise generation

At that earlier checkpoint, the app lock pinned MilkRust `836cd3275681a697f16cca65e50037f7cdc61f5b` (ABI v2). The engine included bounded
APNG and animated WebP decoding through the shared Rust path, native static PNG/WebP
decoding, a bounded Texture2D Gather family in the HLSL compiler, and per-renderer
runtime-seeded built-in noise shared by native GL and WebGL. A deterministic noise
generator remains available for offline callers.

This pin is source-only and unqualified. Builds, decoder/import execution, browser and
native rendering, reference-pixel comparisons, and device runs remain unperformed on
the compatible private JIT runners. Noise pixel identity and mobile recovery behavior remain unqualified; the Apple
lifecycle and interrupted-preset source policy is implemented but not device-tested.

## 2026-10-30 earlier MilkRust comparison-sampling source checkpoint

At that earlier checkpoint, the app lock pinned MilkRust `e940530aa1904f145f7f7006ada9d7ef9fb3ce2d` (ABI v2). This source adds Texture2D `GatherCmp`, `GatherCmpRed`, `SampleCmp` and `SampleCmpLevelZero` for statically initialized comparison samplers. The implementation covers all eight comparison functions, the supported point/linear min/mag/mip profiles, Wrap/Clamp/Mirror addressing and literal int2 offsets. It compares red-channel texels before filtering and computes implicit LOD from texture-coordinate derivatives. Other texture dimensions, dynamic state and exact pixel parity remain open.

The pin remains `source-only-unqualified`. There is no Actions run for the new MilkRust revision, and the connected GitHub tool has no workflow-dispatch action for PlezyNG's private JIT jobs. No build, test, render or device qualification was performed for this checkpoint.

## 2026-10-30 Texture1D comparison-sampling source checkpoint

The app lock now pins MilkRust `893a04399b5e02db8d201701a72f8c4a3ce61791` (ABI v2). Texture1D `SampleCmp` and `SampleCmpLevelZero` now share the bounded comparison filter and implicit-LOD path with Texture2D, using the existing center-row mapping and a scalar literal offset. A one-row backing image is required for Texture1D parity; GatherCmp remains Texture2D-only. Texture3D/cube comparison methods remain unsupported. The pin remains `source-only-unqualified`; no build, test, render or device qualification ran for this source update.

## 2026-10-30 integrated shader overload and comparison-binding checkpoint

The app pins MilkRust `893a04399b5e02db8d201701a72f8c4a3ce61791`, ABI v2, preserving the
animated-image, runtime-noise and Texture2D gather/comparison changes. Global
resource groups retain each initializer/array independently. Static resource
helpers preserve numeric overloads, different arities, prototypes and calls
between overloads; ordinary arguments are evaluated once. The typed call graph
rejects actual direct/indirect recursion before GLSL generation.

Comparison-only state now activates helper specialization. Generated
Gather/GatherCmp/SampleCmp bindings are included in resource discovery, and
comparison resource-array dispatch preserves scalar versus four-component
results. The bounded HLSL profile still has explicit resource/language limits;
this does not assert universal DirectX compatibility or reference-pixel parity.

Native compiler and browser pixel regression sources cover these paths. This
continuation passed source whitespace, JavaScript syntax and app JSON/workflow
YAML parsing. No compiler, unit test, GPU or device execution has occurred.
Confidence is moderate in integrated source behavior and unknown for platform
execution. The existing private-only workflows require manual dispatch, which
the connected GitHub tools do not expose. The original build, mpv artifact,
conformance, content and production-release gates remain open.


## 2026-10-30 MilkRust comparison-gather and static-state alias source checkpoint

The app lock now pins MilkRust `a0ce0242eef5372501a3a6036569e53fb8ad7239` (ABI v2). The bounded HLSL
profile lowers all five Texture2D comparison-gather channel methods:
`GatherCmp`, `GatherCmpRed`, `GatherCmpGreen`, `GatherCmpBlue`, and
`GatherCmpAlpha`. Their selected channel is compared independently at each
of the four D3D-ordered texels. Global `SamplerState` and
`SamplerComparisonState` declarations may alias another statically
initialized global state, including forward aliases and alias chains; lowering
preserves filter, address and comparison function, and rejects unresolved or
type-mismatched aliases. Native regression sources now cover every channel,
static aliases, invalid targets and type mismatches.

This is source implementation only. No Rust/C++ build, compiler suite,
browser run, render, reference-pixel comparison or device run was performed.
The connected GitHub actions expose no workflow-dispatch operation, and the
PR's private JIT runners remain the required execution environment.


## 2026-10-30 MilkRust sampler-state alias follow-up

The source lock pins MilkRust `81593b2657c9de2bd6ea4f1903a9f992a3572800` (ABI v2). Static global ordinary and
comparison sampler aliases preserve their target profile, including forward
chains, while helper parameters are excluded from global alias tracking. This
avoids collisions between same-named sampler parameters in overloads and keeps
the alias model limited to actual global declarations. Existing native source
regressions cover helper overloads, channel gather variants, aliases, unresolved
targets and ordinary/comparison type mismatches.

No build, test, render, reference comparison or device check was performed.
The private JIT workflow still has no connected dispatch action; this remains
an unqualified source pin.

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


## 2026-10-30 resource-bearing HLSL helper arguments

PlezyNG now pins MilkRust `1ab258e889d1932395e22015c383695611b918a5` (ABI v2). HLSL helper functions may take a direct resource-bearing struct parameter when each call supplies an unambiguous global struct instance. Specialization substitutes the global binding before ESSL lowering; local and dynamic resource-bearing struct arguments fail closed. Native regression source covers the global and local cases. The pin remains `source-only-unqualified`: the latest engine commit has no attached Actions run, and the connected GitHub tool exposes no workflow-dispatch operation for the required private JIT jobs. No build, test, compiler execution, render or device qualification was performed.


## 2026-10-30 upstream sprite blend contract correction

MilkRust PR #20 now pins `994e09dbec15702b03126011f1dcc21d7461f124` (ABI v2).
Standard MilkDrop sprite `blendmode` defaults to 0, is evaluated after each
frame's sprite equations, truncates to int, and clamps to 0..4. Explicit
`SpriteBlend` selects the optional MilkRust 11-entry table; modes 5..10 are
engine extensions. The app lock and this summary match that behavior. The
private JIT compiler/build tests and reference/device rendering remain pending.


## 2026-10-30 global resource-struct initializer support

The runtime lock now pins MilkRust `d7a646af44dc1fbd8d328bf607eaceaa63a46534` (ABI v2). Global resource-only structs accept direct aggregate initializers that alias compatible global texture bindings, including helper specialization over multiple global instances. Mixed numeric/resource, computed, local and mismatched-resource initializers fail closed. The change adds Rust source regressions but has not been built or run; the private runner and device checks remain open.


## 2026-10-30 initialized resource alias shape guard

PlezyNG now pins MilkRust `86f48b621737aebfbed05b40869f357ebebe4b6f` (ABI v2). Global resource-only struct aggregate aliases must match the source texture dimension and scalar/vector component width. Regression sources cover Texture1D versus Texture2D (which share the legacy GLSL sampler type) and float versus float4 element widths. The source remains unbuilt and unrun; private JIT compiler and renderer qualification remain pending.

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


## 2026-10-30 current MilkRust source pin — corpus accounting

The runtime source lock now pins MilkRust `ca0a94321aadd3b48a9eed9b266796f5ce9a1c03` (ABI v2), preserving the texture-only pack schema/delivery work and initialized resource-struct aliases while adding source-shape validation and complete compatibility-report accounting. The compiler rejects resource aliases whose original texture dimensions or scalar/vector element widths differ. The CLI retains every discovered preset path, reports bounded traversal failures, separates input-limit rejections from I/O errors, and reports empty roots. The report generator preserves file and per-preset outcomes, reconciles every manifest path against discovery, and records missing/unlisted paths and scan/read/decode failures.

New Rust and Node regression sources cover these cases. The checked-in community summary was not regenerated; its historical 37-file discrepancy still needs a full private-runner report. Builds, tests and rendering remain unqualified, and this tooling change does not close the renderer/profile gaps.


## 2026-10-30 nested resource-struct source continuation

MilkRust PR #20 commit 7a83ea328be14c4c9acddb24079ef8ac2658b45a now lowers scalar texture fields nested through plain structs when accessed through a global instance. The compiler preserves leaf dimension/element width, resolves full dotted paths, specializes resource-bearing helpers to global instances, and dispatches literal and side-effect-free dynamic indices for bounded resource arrays nested through those paths. Regression sources cover direct/helper access, static/dynamic array selection, binding reflection and rejected nested aggregate initializers. Function-local arrays, nested aggregate initializers and nested sampler-state propagation remain unsupported. This is source only; compiler, browser, native render and device gates remain pending.


## 2026-10-30 immutable local resource-struct alias source continuation

MilkRust PR #20 now includes commit 1cfb07306f0ced0b93f5d8aa13e4d5f55782b103 (ABI v2). A local resource-only struct copy initialized directly from a matching global instance is normalized to that binding before opaque-resource specialization. The rewrite is restricted to direct declarations in a function or shader body and rejects mutation, shadowing, mixed structs, computed/aggregate initializers and uninitialized locals. PlezyNG pins this source revision. No compiler, build, test, browser, render or device run was performed for this checkpoint.


## 2026-10-30 statically indexed local opaque-array source continuation

MilkRust PR #20 now includes commit 467adacec200d0fd5551cf5b5c9dee9d0621f750 (ABI v2). Fully initialized function-body or shader-body opaque arrays of 1–15 entries normalize to matching global resource/sampler bindings when every use has a literal index. Computed/partial initialization, dynamic indices, writes, shadowing and nested-scope declarations remain unsupported. PlezyNG pins this revision. No compiler, build, test, render or device run was performed for this checkpoint.
