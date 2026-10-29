# Desktop PME display-sync input evidence — 2026-10-29

## Change

The local mpv patch series adds `0157-desktop-pme-sync-timing.patch` to both the Linux and Windows series. The output-filter stream information now exposes mpv's current VO vsync interval and effective video playback speed, including display-sync speed correction. The PME phase planner uses those values for its error-diffused phase count and resets the diffuser when either rate changes.

This removes the mismatch where the planner used nominal monitor FPS and media timestamps while mpv scheduled frames using an adjusted video speed and measured vsync interval. Mpv still applies per-frame A/V-sync drop/repeat corrections after the PME phase plan; the filter does not receive those actual `num_vsyncs` decisions. This patch therefore improves schedule alignment but does not establish cadence-exact output.

## Local build

- Source: `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-source-phase-cadence-20261028/`.
- Build: `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-build-phase-cadence-vulkan-full-20261029/`.
- `git apply --check` accepted patch 0157 on top of patches 0155 and 0156.
- `ninja -C ... mpv` rebuilt the Vulkan-enabled mpv 0.41.0 executable successfully, including `filters/f_output_chain.c`, `player/audio.c`, `player/video.c`, and `video/filter/vf_plezy_pme.c`.
- The build emitted existing `-Wmisleading-indentation` warnings in PME image helpers and an unused Vulkan helper warning; it had no build errors.

This is source-build evidence only. It does not include a real display run, ANVIL inference after this change, frame-timestamp review, visual quality, A/V-sync, or Windows playback. No CI was run, and the patch remains outside PlezyNG's pinned mpv artifact.
