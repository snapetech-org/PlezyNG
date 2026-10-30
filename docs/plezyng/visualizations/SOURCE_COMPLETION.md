# Visualization source completion

Updated 2026-10-30. **Code implementation: 100% complete for the plan's
documented native/WebGL legacy profile and app workflow.** This records the
user-requested code gate. It does not assert that compilation, tests, reference
comparisons, device qualification or release publication have passed.

The original plan remains in COMPLETION_PLAN.md. Its product/custom-engine
acceptance gates remain independent. New defects found during those gates must
be fixed; source completion is not a claim that every current or future preset
is compatible.

## Completed source packages

| Plan package | Implemented source |
| --- | --- |
| V0 audit and accounting | MilkRust compatibility CLI preserves every discovered-file outcome; report generation retains denominator, manifest joins, read/encoding/parse/compiler failures and original paths. npm entrypoints and negative regression sources are wired. |
| V1 native integration | Shared lifecycle/capability/control contract; Linux projectM and MilkRust hosts on Linux, Windows, Apple, Android/TV, Tizen and webOS; native textures, generation leases and explicit load failures. |
| V2 playback audio | Ordered same-player mpv PCM extension and Android bridge in the pinned build source; bounded analysis transport, seek/generation reset, stereo analysis and original-scene features; explicit TV/casting/passthrough availability. |
| V3 parser and VM | Standard keys, legacy encodings, isolated equation state, bounded execution/memory, object/wave semantics and diagnostics; converted numeric semantics are implemented without a JavaScript runtime. |
| V4 rendering | Typed bounded legacy HLSL in native/WebGL; distinct warp/draw/blur/composite passes, texture/noise/matrix bindings, classic geometry, saved pairs and all documented saved patterns/sprite controls. |
| V5 packs/catalog | Deterministic archives, per-file provenance/integrity, immutable texture dependencies, texture-only packs, thumbnails, signed catalog/rotation/revocation and publication gates. |
| V6 local library | Bounded loose/folder/ZIP/rmpack import, atomic install/recovery/removal, dependency-aware shared texture storage, private resolved views, preset/assets/notices export, shape/wave export and composition into a new copy. |
| V7 downloads | Explicit catalog fetch/install/update/remove, durable bounded staging, ETag/Range-validated resume, cancel/retry/discard, checksum validation and offline use. |
| V8 app controls | Search/favorites/playlists, engine and per-preset capability negotiation, lock/shuffle/timing/transition/fullscreen/input controls, persisted profile choices and adaptive native resolution/frame pacing. |
| V9 qualification tooling | Source regressions, fault/lifecycle controls, private JIT jobs, reference/corpus evidence formats and per-target qualification gates. Execution and physical-device results are pending. |
| V10 release tooling | Runtime/source/notices packaging for each claimed platform, mpv artifact promotion tooling, signing-root configuration, protected publisher/preflight and release documentation. Credential/artifact production and publication are pending. |

## Final code closure

The final source changes close durable downloads, adaptive quality, immutable
texture dependency resolution, preset/fragment authoring/export, and the
previously shaderless-only Butterchurn converter.

Butterchurn JSON now has bounded numeric/control-flow conversion and generated
GLSL lowering to the typed compiler. Original and transformed hashes remain
separate. Converted presets carry a versioned MilkRust requirement in both
their manifest and text, so export/import cannot silently offer them to
projectM. Matrix orientation, float remainder, exact truth/equality, 32-bit
shifts, assignment ordering, numeric Math operations and both shader stages
have implementation and regression source.

Fragment composition uses the four real custom-object slots. Texture
dependencies pin exact integrity indexes, protect installed dependents and
resolve aliases without copying source packs into each consumer.

## Validation and delivery still pending

- Compile/link, tests, corpus conversion runs, driver execution and reference
  pixel/behavior comparisons on compatible private ephemeral JIT runners.
- Installed app, audio ownership, accessibility/localization, performance,
  lifecycle and physical-device qualification for each platform.
- Production of the new mpv/runtime binaries, promotion of their actual digests,
  generation/rights review/qualification of candidate packs, reviewed signing
  custody/public root, and release/catalog publication.

None of those pending results is recorded as passed. The source lock retains
source-only-unqualified. Current release binaries and remote catalog
provisioning are not changed by this source-completion designation.

## Fixed scope and platform limits

The HLSL contract is MilkRust's documented legacy pixel profile, not every
modern DirectX resource, compute stage or future syntax. The separate WGSL path
keeps its own documented limits. Unsupported inputs fail explicitly and remain
in corpus accounting.

Butterchurn conversion is a bounded numeric/generated-shader profile, not
arbitrary JavaScript. Unknown host APIs and unbound resources are rejected.
MilkDrop 3 source behavior is implemented; reference-pixel fidelity remains a
validation result to establish, not another feature implied by this ledger.

Desktop/Android/TV renderer process boundaries and Apple's foreground/recovery
policy are implemented. No application can promise recovery from a device-wide
GPU/kernel hang. iOS/tvOS use the documented bounded in-process retirement and
interrupted-preset recovery policy. TV PCM availability and webOS file limits
remain explicit capability boundaries.

## Source evidence

- App services: lib/services/visualization/
- Browser and controls: lib/widgets/music/music_visualizer.dart,
  visualizer_library_sheet.dart and visualizer_preset_browser.dart
- Shared worker/protocol/budgets: shared/visualization/
- Runtime/PCM inputs: native/visualizer/sources.lock.json and README.md
- Engine/compiler/format source: MilkRust PR #20, crates/
- Conversion: MilkRust tools/convert_butterchurn.py and
  docs/BUTTERCHURN_CONVERSION.md
- Pack dependencies and delivery: MilkRust tools/validate_pack_dependencies.py,
  package-rmpack.py, signed_catalog.py and catalog_qualification.py
- App/native regression sources: test/services/visualization/ and test/native/
- Operational handoff: BUILD_HANDOFF.md and CATALOG_RELEASE.md
