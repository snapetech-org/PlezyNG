# OS-scheduled retained-WAV transcription

The transcription queue offers a per-job **Allow OS background transcription**
switch. It is off by default and requires an already installed speech model.
Enabling it schedules separate subtitle work through Android WorkManager, iOS
BGProcessingTask, or the existing desktop per-user scheduler infrastructure.
Desktop workers start hidden with `--plezy-subtitle-worker`. Remote-media
preparation keeps its own task identifiers, network requirement and entry point.
Subtitle work does not require network access and cannot download a model.

Only CPU and desktop GPU Whisper jobs are eligible because the native session
supports cooperative cancellation; accelerator requests with uninterruptible
inference stay in the foreground. Jobs requiring confirmed playback idle also
stay in the foreground because the headless worker cannot observe every player.
The worker has a five-minute admission budget and processes retained WAVs in
the same bounded 30-second windows/checkpoint format as the foreground queue.
Only the last active, authorized profile can run; switching profiles retires that
authorization. Profile deletion/account sign-out revokes background work before
identity removal. Retained jobs require a fresh explicit opt-in after re-entry.
Jobs rotate within the active profile. Existing
power policy is retained. A missing or changed model pauses a job for foreground
recovery. Whisper verifies the installed catalog model and opens its local path
directly; Sherpa refuses missing installed assets. Successful inference retains
the existing provider/fallback disclosure and does not establish device placement.

Each queue owner holds a SQLite writer transaction in a separate ownership
database throughout file access and native work. This is not a time-based lease:
an engine suspension cannot allow a second checkpoint writer. Foreground
profile/lifecycle transitions retire generations, wait for native calls,
imports and writes, then release ownership. A foreground return requests worker
retirement and waits to reload its queue until ownership is released. The worker
also checks native mobile activity, a short-lived desktop foreground marker and
a monotonic deadline. Incomplete windows are discarded. Whisper supports
cooperative cancellation; a Sherpa native window must return or be terminated
with its headless engine. No lock is voluntarily released around an outstanding
native call. Process death releases SQLite ownership; the existing backup and
window recovery path runs only after the next owner acquires it.

OS installation and idle removal use a separate cross-engine gate. A producer
saves its journal before installing work under that gate; cleanup cannot cancel
a newer producer's installation. Unreadable or currently owned profiles prevent
idle removal. Tasks are removed after the worker establishes that no eligible
queued jobs remain. Android retains battery-not-low constraints; the OS may delay
or end work, and scheduling does not promise continuous or timely execution.

Owned-source leases still require the foreground source owner. A headless engine
cannot establish that every playback owner is idle, so jobs with **playback idle**
policy wait for foreground execution. Background eligibility does not relax that
policy. No GPU/memory/thermal qualification or cross-engine playback-latency
guarantee is implied by the source implementation. Results never auto-attach.

All changes are source-only. No scheduling, models, tests, analyzers, builds,
dependency installation, CI or device qualification were executed.
