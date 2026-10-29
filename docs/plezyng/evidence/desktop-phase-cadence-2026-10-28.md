# Desktop PME phase-cadence prototype — 2026-10-28

## Status

An experimental follow-on patch, `0155-desktop-pme-display-phases.patch`, is
present in the local `mpv-build` worktree and is included in its Linux and
Windows patch series. The patch applies to both pinned mpv source trees. A
local Vulkan-enabled Linux cplayer was compiled from the patched source; the
patch is not in a published mpv artifact or PlezyNG's `mpv-build.lock.json`.

The phase planner estimates display slots from source timestamps and mpv's
reported display rate, with error diffusion and per-preset phase caps of 1, 3,
and 7. It supplies arbitrary interpolation alphas to the existing midpoint
graph and tapers its midpoint-trained residual by `4α(1−α)`. That is an
approximation, not a time-conditioned model. The planner cannot read mpv's live
`num_vsyncs` decisions or AV-sync corrections. The multiphase path uses CPU
warping; Vulkan remains available for the single-phase path. No visible output
or model-quality qualification has been completed.

The patch also fixes the one-worker queue search so its single runtime can
process either queued job slot sequentially; the separate output queue preserves
source order. A worker-queue diagnostic before that change reported rejected
submissions while one job was queued (`slot=-1`, `queued=1`).

## Local evidence

- Linux and Windows patch-apply source trees are retained at
  `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-source-queue-fix-linux-20261028`
  and `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-source-queue-fix-windows-20261028`.
- The Vulkan-enabled cplayer is
  `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-cplayer-vulkan-cadence-20261028/mpv`;
  its build log is
  `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-cplayer-vulkan-build-20261028.log`.
  This local build used a task-specific pkg-config overlay with the host's
  Vulkan-capable libplacebo; it is not a shipping artifact.
- Before the queue fix, a five-second null-VO run reported 59 generated frames
  from 121 source frames at a reported 60 Hz display rate. After the queue fix,
  another five-second run reported one generated frame, three deadline misses,
  113 bypassed frames, and a 9.686 ms pipeline sample. Both used
  `TestOnlyBlendStub`, an arithmetic blend stub rather than ANVIL or another
  neural model.
- These null-VO runs do not exercise physical display presentation. Their
  conflicting scheduler results are inconclusive for cadence, visual quality,
  audio/video sync, or hardware performance. The logs are retained at
  `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-phase-scheduler-run7-vulkan-20261028.log`
  and `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-phase-scheduler-fixed-run-20261028.log`.

## Remaining qualification

The phase patch needs a real display-output run with a neural model, checks of
frame timestamps and repeated/dropped slots, visual review, and audio/video
sync qualification. Windows has patch-application evidence only; no Windows
build or device playback was done. The PlezyNG lock still references the
pre-PME mpv artifact. No CI was used.
