# Native cue alignment and calibration history

Library MPV timing controls now expose a searchable cue picker for the selected
SRT/WebVTT/ASS/SSA sidecar. Both native subtitle lanes can align a selected cue
to the current opened-file position. Standalone imports use the same picker
with their retained asset and existing source-owned persistence. The picker
starts at the cue nearest the corrected playhead and captures the fresh native
position when the viewer chooses a line. Multipart item offsets are removed
before calculating native delay, and a changed origin retires the control.

Inspection accepts a bounded local file or the selected sidecar's HTTP(S) URL.
The read is limited to 5 MiB, 50,000 cues, a 20-second overall deadline checked
between reads, five-second network/read waits and three same-origin redirects.
It does not copy server credentials into another transport or follow cross-origin
redirects. Embedded/container and bitmap tracks have no file picker capability;
use the existing extraction/import paths first. Live library playback does not
offer these fixed-file tools. Native cue-step remains available independently.

Corrected library sidecars export as a ZIP containing unmodified original bytes,
the corrected subtitle and a JSON manifest with hashes, delay/rate, lane, omitted
cue count and opened-file/item-clock mapping. It contains no media URL, credential
or source path. Before-zero omission requires confirmation. ASS timing support
and refusal conditions follow ASS-RETIMING.md. Export does not attach a track.

Primary native text calibration now accepts 2–12 explicit observations. It uses
the median of pairwise slopes over spans of at least 60 seconds and the median
intercept, retaining every observation. The dialog shows each signed residual,
the largest absolute residual and RMS. A residual above 750 ms blocks preview
and save, requiring correction of observations or the separate cut-aware path.
Rate remains bounded to 0.8–1.25 and delay to ±60 seconds. These are declared
consistency bounds, not measured perceptual quality thresholds.

The prior value and accepted correction are kept in profile-local history,
including supplied anchors. The scope includes content/copy identity, player,
opened-part offset, selected audio and subtitle lane identity; transport secrets
are omitted from its hash inputs. History is bounded to 64 scopes, eight records
per scope and 512 KiB per profile. Loading a record only fills the dialog; preview
and save remain explicit. Existing native readback, serialized writes, cancel
rollback and one-step undo remain in use. History failure does not misreport a
successfully applied native correction as a failed timing change. Representation
metadata alone cannot detect a server replacing bytes under an unchanged catalog.

New controls use central English strings and the existing language fallback.
No formatter, analyzer, test, build, file-picker invocation or device run was
performed. Source integration confidence is moderate; runtime and rendering
confidence remain unknown.
