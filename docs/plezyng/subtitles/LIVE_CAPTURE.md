# Live and DVR caption capture

Capture is opt-in and uses the active player's decoded PCM tap. It does not
change passthrough, tunneling, offload, channel layout or the selected audio
track. Android reports capture unavailable until its active output is decoded
PCM. Native mpv still requires the packaged capture ABI to report availability.

PCM is bounded to 24 seconds. Live cue and word history retain at most two hours
on the current timeline, also subject to cue and word-count bounds. Pausing does
not advance the media clock. An explicit DVR seek drops pending inference and
pre-seek queued packets, and can reuse retained captions. A backwards clock jump
without a declared seek invalidates all old cues before accepting the new epoch.
Format changes reset the inference window. Channel, media-session and selected
audio-track changes stop capture and discard captions from the old source.

Same-channel server DVR seeks that reopen a source suspend capture through the
live-session owner. When the new rendered clock is accepted, caption positions
are rebased onto the original timeline and capture resumes. Failed or superseded
opens discard the handoff. This uses the existing live clock and seek ownership
guards; channel replacement is never treated as a DVR seek.

Captions and transcript text stay in memory until explicitly exported or used
in a reviewed subtitle operation. Retention does not imply that a DVR server
still holds the corresponding media. Seeking to a retained cue requires that
position to remain available to the player.

Source regression cases cover clock rollback, stale queued packets after a DVR
seek, pauses and format changes. Device execution, native ABI qualification and
server DVR handoff execution remain pending.
