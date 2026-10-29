# Bounded live DASH subtitle analysis

The library/live-TV analysis lease now recognizes `.mpd` and `dash+xml` sources.
Only that separately owned lease converts a supported MPD into a local manifest
of complete audio fragments. The audible player's transport is unchanged.
Standalone live-input analysis remains capability-limited by its source owner.

Choose the audio representation in document order and **audio stream ordinal
0**: a DASH representation supplies one audio stream. This ordinal is independent
of native track IDs. The UI asks viewers to verify the language. A change in
representation, language/codec/sample-rate metadata or initialization path stops
the job and requires a new explicit choice.

Supported inputs require:

- A dynamic MPD in the DASH namespace, explicit UTC availability and publication
  timestamps, and `audio/mp4` representations with IDs and bandwidth metadata.
- One `BaseURL` per hierarchy level, inherited `SegmentTemplate`, explicit
  `SegmentTimeline` and timescale, and separate initialization/media URLs.
- `$RepresentationID$`, `$Bandwidth$`, `$Time$` and `$Number$` substitutions,
  literal `$$` and numeric zero padding up to 12 digits.
- Ordered, non-overlapping periods and finite `S` runs. `r=-1` is bounded by an
  explicit next `S@t`, period end or the MPD publication clock. Period starts
  after the first must be explicit.

The source clock is availability start + period start + (sample time −
presentation-time offset) / timescale. Integer/BigInt arithmetic bounds clock
conversion and avoids multiplication overflow. A segment is considered for
reading only after its complete declared interval precedes the publication
timestamp and still intersects the declared time-shift buffer. Publication time
is a conservative manifest snapshot, not the client's request/receipt clock.
The server must still return complete bytes; transient segment absence uses the
existing retry policy. No future or partial audio is invented.

Duration-only templates are refused because their timing can be nominal rather
than sample-exact. Protected content, nonzero availability offsets, incomplete
segments, XLink/XML-base indirection, leap-second adjustments, SegmentList,
SegmentBase/index addressing, alternate `S@n`/partial `S@k`, `eptDelta` and
period-boundary clipping are unsupported. DTDs/entities are refused. Unknown
or incompatible formats fail closed; no external manifest URL is passed to the
decoder. UTC service fetching and wall-clock synchronization are not added.

Input limits are 1 MiB, 20,000 XML events, depth 32, 32 periods, 64 audio
representations and 2,000 complete segment references across the MPD. Segment
duration is capped at 60 seconds. Representations with long/infinite DVR windows
may exceed that bound and are refused. The advertised minimum update period is
respected between 3 seconds and 5 minutes; larger periods are refused. Repeated
segment URLs on different clocks are rejected. Source credentials remain scoped
to the originating host; child renewal uses refreshed MPD references and never
an old ordinal in a new rolling timeline.

The local reader checks the normalized manifest, continuity and representation
identity. Availability-start changes, backwards publication clocks and protocol
changes retire the job. Both desktop/TV and mobile paths validate staged fMP4
boxes, refuse external data references and known protected sample descriptions,
and retain the existing 64-second / 128-MiB staging bounds. Mobile concatenation
and desktop/TV decoding use the existing independent decoder path. Native codec
support, real fragment clocks and output timing still need device qualification.

The source gateway retains owner registrations separately from rolling child
references. Its 4,096-entry cache no longer evicts the live root URL; recently
fetched child playlists have a two-minute grace period. At most 64 owner URLs
are admitted, and a fully active cache refuses admission before mutation.

Confidence: moderate in source integration, unknown in runtime behavior. No
tests, analyzers, builds, decoder execution or CI were run in this pass.

Timing reference: [DASH-IF restricted timing model](https://dashif.org/Guidelines-TimingModel/),
sections 9, 13 and 18.3–18.4. This implementation is a bounded analysis subset,
not a DASH conformance claim.
