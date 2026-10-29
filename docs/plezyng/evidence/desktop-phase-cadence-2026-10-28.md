# Desktop PME phase-cadence prototype — updated 2026-10-29

## Status

The local `mpv-build` worktree includes patches `0155-desktop-pme-display-phases.patch` and `0156-desktop-pme-single-inference-phases.patch` in both its Linux and Windows series. The full series applies to the pinned mpv source for both targets. These patches are not published and are absent from PlezyNG's `mpv-build.lock.json`.

Patch 0155 estimates display phases from source timestamps and mpv's reported display rate, with error diffusion and per-preset phase caps of 1, 3, and 7. Patch 0156 selects the requested phase nearest alpha 0.5, runs one model inference for that source-frame pair, and reuses the resulting residual for the other phases. This avoids one inference per generated phase. The residual is tapered across phases; the midpoint-trained model is still an approximation, not a time-conditioned model. The scheduler cannot read mpv's live `num_vsyncs` decisions or AV-sync corrections. Multiphase warping uses CPU; Vulkan remains available for single-phase jobs.

The 0155 queue fix lets a one-worker runtime process either queued job slot sequentially while the output queue preserves source order. Patch 0156 keeps the single-phase path on its existing inference behavior.

## Local build and source evidence

- The source and patch series are in `/home/keith/Documents/code/task-worktrees/mpv-build-motion-fork-integration-20261028`, branch `codex/motion-pme-overlap-20261028`.
- The fresh full Linux build is in `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-build-phase-cadence-vulkan-full-20261029/`. It contains the mpv 0.41.0 cplayer and `libmpv.so.2.5.0`, built with Vulkan and patch 0156.
- `mpv --version` reports mpv `v0.41.0-dirty`, libplacebo `v7.360.1`, and FFmpeg `n9.0.2`. `mpv --vf=help` lists `plezy-pme`.
- The build directory and binary are local task outputs, not published artifacts. No CI was used.

## Scheduler observations and limits

The retained null-VO scheduler runs used `TestOnlyBlendStub`, an arithmetic stub rather than ANVIL. Before the queue fix, a five-second run reported 59 generated frames from 121 source frames at a reported 60 Hz display rate. After the queue fix, a run reported one generated frame, three deadline misses, 113 bypassed frames, and a 9.686 ms pipeline sample. Logs remain at `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-phase-scheduler-run7-vulkan-20261028.log` and `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-phase-scheduler-fixed-run-20261028.log`.

No visible output, real-model run, frame-timestamp review, model-quality assessment, or A/V-sync qualification has been completed with patch 0156. Earlier hardware inference evidence in the motion-processing record predates this phase-cadence change and does not qualify it.

## Remaining qualification

Run the patched filter with ANVIL on a real display, review generated and repeated frame timestamps, assess visual quality, and measure A/V sync. Build the Windows series and qualify playback there. Update and publish the PlezyNG mpv artifact pin only after platform artifacts and qualification are available.
