# Desktop PME adaptive phase budget

The desktop MPV patch candidate adds a bounded phase-density governor to the Linux and Windows patch series. A deadline miss caps subsequent pairs at one fewer generated phase than the affected pair. The limit recovers one phase after 120 consecutive on-time pairs. MPV metadata exposes both the active limit and the preset maximum; PlezyNG carries these into `PlaybackCapabilityReport` and the performance overlay.

The governor reduces display-phase reconstruction work. It does not switch models or change model resolution after the provider session has initialized. The existing three-misses-in-two-seconds bypass and ten-second single recovery probe remain active. Cadence-exact presentation remains unqualified because MPV's final vsync and later A/V-sync corrections are not observed.

## Source and validation

- MPV build branch: `codex/motion-adaptive-phases-20261029`, current commit `3a8181c09e502e3c14f64387ab3a3cb5051f8d68`, based on the pushed `codex/motion-pme-overlap-20261028` source series. Patch 0159 was first committed as `ca09fae`; patch 0160 was added at `d27f3cc`, and the current head records the Windows artifact manifest.
- Patch `0159-desktop-pme-adaptive-phase-budget.patch` was added after patch `0158` in `series.linux` and `series.windows` only. Patch 0160 adds source-shape resampling and is recorded separately in the [artifact gate evidence](mpv-motion-artifact-gate-2026-10-29.md).
- The complete common and Linux series applied to MPV v0.41.0 source commit `41f6a64506`. Patch `0159` passed reverse-apply checking and forward-apply checking; `git diff --check` passed.
- With GCC 16.2.1, Meson 1.12.1, and Ninja 1.13.2, the PME filter object compiled with `PLEZY_HAVE_PME_VULKAN` enabled. The only compiler warnings were existing misleading-indentation and unused-function warnings in other parts of the PME filter.
- The full `libmpv.so.2.5.0` target compiled and linked against the retained local patched libass static prefix. That Meson configuration had Vulkan disabled because its libplacebo reports `pl_has_vulkan=0`; the separate Vulkan-enabled filter-object build covers the PME Vulkan code path. An initial full build against system libass 0.17.5 stopped in `sub/sd_ass.c` because that library lacked APIs supplied by PlezyNG's libass patch series.
- PlezyNG's focused `performance_stats_service_test.dart` passed all 25 tests, including a new check for active/configured PME phase-budget metadata.

These checks establish patch applicability, compilation, linking, and telemetry parsing for the initial 0159 source candidate. The later 0160 source and Linux package passed a synthetic 720p CPU wiring smoke; its deadline failures and qualification limits are recorded in the [artifact gate evidence](mpv-motion-artifact-gate-2026-10-29.md). No real-display, device, NPU, cadence, A/V-sync, thermal, or visual-quality qualification has been performed. The package is not present in the app's pinned MPV artifacts. No CI workflow was changed or dispatched.
