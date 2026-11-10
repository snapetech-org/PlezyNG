# Music download and station storage policy

Music downloads retain the original audio representation. Streaming bitrate
preferences do not convert downloaded music. Downloaded lyrics and versioned
loudness analysis are optional; missing or outdated analysis does not prevent
playback and does not enable a fade based on stale data.

Saved stations can limit track count, listening time, and estimated download
bytes. A zero storage budget leaves the station unlimited. Estimates prefer the
sum of all file parts in the first media version, then its reported bitrate and
duration. Sparse metadata uses a 1,536 kbit/s duration estimate. Tracks without
enough information for an estimate are excluded when a storage budget is set.
Whole-album stations skip an album rather than splitting it to fit a budget.

Scheduled refreshes count the known downloaded/reserved bytes of copies already
linked to that rule before admitting another batch. A linked active download
with an unknown total prevents additional admission until its size is known.
These are admission estimates, not a guarantee of final file size: a server can
return a larger representation. Existing downloads are never silently deleted
to make room, and the download manager's device free-space checks still apply.
Manual previews apply the selected batch budget; the scheduler additionally
accounts for previously linked copies across refreshes.

Retry batches retain their exact candidates, account scope, and original byte
estimates separately from offline station snapshots. A retry with invalid source
identity, changed rules, or corrupt estimates is regenerated rather than queued.
Completed snapshot metadata is bounded to 64 snapshots and 64 MiB per profile.
Pruning this metadata does not remove audio files, download ownership, station
rules, or pending retries. Legacy pending snapshots migrate before pruning, and
a newer retry record takes precedence over an older legacy snapshot.
