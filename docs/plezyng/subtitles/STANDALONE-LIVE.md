# Standalone live analysis

The source player can open a separate analysis lease for an eligible HTTP live
input. It retains the owning adapter or transient URL/header registration and
uses the bounded HLS/DASH analysis gateway. It does not reuse the audible decoder
or change audio passthrough. Sample-only, provider-restricted stream-only, capture-device, local live
file and unsupported transport inputs remain refused.

Explicitly opened file/HTTP inputs carry a separate transient-analysis grant.
Their `streamOnly` flag controls persistent downloading and does not itself mean
provider protection. This also enables eligible directly opened VOD files/URLs
to use read-ahead, embedded-font inspection and explicit companion staging.
The grant requires ephemeral playback with a supplied file/HTTP override for
every selected file; it is absent for provider streams and capture devices.

Standalone playback exposes no automatic UTC program-clock mapping. Starting
read-ahead therefore requires an explicit paused-frame anchor: the viewer supplies
the actual program timestamp of that frame in UTC, with no default derived from
the current wall clock or playlist edge. Invalid calendar dates are refused.
The exact paused position must still match when the anchor is accepted.

The mapping is session-only and estimated. It expires after 15 monotonic minutes
and is retired after source/profile/media/seek-generation changes, timeline-offset
changes, invalid rates or detected backward/implausible forward position jumps.
Paused playback keeps a fixed program time. Normal progress and rate changes use
the player's clock, not elapsed time as a replacement clock. The elapsed-time
check only rejects impossible jumps; it cannot prove correct source timing.

Complete segments near or ahead of that mapped position enter the existing local
decoder/inference path. The app displays only cues matching the mapping. No DVR
bounds, rewind support, delay hold or confirmed timing are inferred. Resume
playback after starting; re-anchor after expiry or discontinuity. Closing or
changing a source retires access and stale overlay visibility. Analysis consumes
additional bandwidth and replaces app caption lane 1 after a result is ready.

Source implementation confidence is moderate; anchor accuracy depends on the
provided reference and the backend timeline. No test, build, analyzer, decoder
execution, stream/device qualification or CI ran. Automatic clock discovery for
these standalone inputs remains open.
