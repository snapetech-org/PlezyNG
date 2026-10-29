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

Android ExoPlayer now supplies an atomic Media3 window observation when the
active live timeline declares a UTC start. Starting read-ahead first requests
that clock. The lease refreshes twice a second, rejects bridge calls taking more
than one second and samples whose source position differs from the current app
position by more than 750 ms, and hides program-clock captions after two seconds
without a fresh matching observation. Seeking suppresses the previous sample
until a new observation; source/profile/part/native generation changes retire
the lease. No wall-clock time or manifest duration is used to invent an origin.
The asynchronous bridge and timeline remain an estimated alignment.

Only a non-placeholder, seekable backend window with a known duration supplies
DVR expiry bounds. Standalone live controls now expose the existing explicit
5–120 second DVR delay/hold dialog when this backend supplies a seekable window.
The native epoch seek re-reads the window at dispatch and refuses an expired
target or generation. It uses millisecond positions and excludes the window's
end; the app does not seek by a stale cached window offset. Targets and observed
playback remain estimated, not frame-confirmed. A failed/expired request, a
viewer seek, pause/rate/audio/source/profile change or stale clock stops hold.
Closing the dialog keeps polling only while an explicitly enabled hold owns it;
stopping the hold releases that clock. No source reload or output change occurs.
Ads, backend fallback, terminal playback and missing clocks produce no mapping.
Other backends still use the manual path. The native clock is independent of
PCM routing, so using it does not change passthrough, tunneling or the output.
The API semantics follow [Media3 Timeline.Window](https://developer.android.com/reference/androidx/media3/common/Timeline.Window).

If no usable backend sample is available, read-ahead requires an explicit
paused-frame anchor: the viewer supplies
the actual program timestamp of that frame in UTC, with no default derived from
the current wall clock or playlist edge. Invalid calendar dates are refused.
The exact paused position must still match when the anchor is accepted.

The manual mapping is session-only and estimated. It expires after 15 monotonic minutes
and is retired after source/profile/media/seek-generation changes, timeline-offset
changes, invalid rates or detected backward/implausible forward position jumps.
Paused playback keeps a fixed program time. Normal progress and rate changes use
the player's clock, not elapsed time as a replacement clock. The elapsed-time
check only rejects impossible jumps; it cannot prove correct source timing.

Complete segments near or ahead of that mapped position enter the existing local
decoder/inference path. The app displays only cues matching the mapping. No DVR
bounds, rewind support, delay hold or confirmed timing are inferred from a manual anchor. Resume
playback after starting; re-anchor after expiry or discontinuity. Closing or
changing a source retires access and stale overlay visibility. Stopping the
analysis lease also stops clock polling and hides its program-clock overlay.
Analysis consumes
additional bandwidth and replaces app caption lane 1 after a result is ready.

Source implementation confidence is moderate; anchor accuracy depends on the
provided reference and the backend timeline. No test, build, analyzer, decoder
execution, stream/device qualification or CI ran. Automatic discovery outside
the Media3 path remains unavailable.
