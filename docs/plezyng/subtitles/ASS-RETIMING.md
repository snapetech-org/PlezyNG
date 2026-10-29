# Authored ASS timing export

The existing corrected ASS/SSA export now retimes authored override clocks for
the same affine multiplier used on event start/end times. Original bytes stay
unchanged; output retains styles, geometry, drawings, font sections, formatting,
encoding/BOM and line endings. Pure delay corrections preserve relative timing.

The override parser operates inside balanced brace blocks. It scales `\k`,
`\K`, `\kf`, `\ko` durations and `\kt` absolute syllable starts in
centiseconds. Cumulative karaoke boundaries are rounded before durations are
reconstructed, avoiding repeated per-syllable rounding drift. A `\kt` resets
that cumulative clock. Omitted libass karaoke durations are emitted explicitly
when scaling (100 centiseconds, or zero for `\kt`).

Explicit `\move` and `\t` timing intervals, `\fad` durations and all four
`\fade` time points scale in milliseconds. Coordinates, alpha values,
acceleration and animated style modifiers are retained. Four-argument movement
and transforms without explicit times continue to span the retimed event.
Parentheses inside transform modifiers, such as rectangular clips, remain intact.
Nested time effects inside a transform are refused because they have no shared
portable semantics. Unknown non-timed override text is left with its native
renderer; this is not a new ASS renderer or a repair of malformed scripts.

Legacy `Banner` and `Scroll up`/`Scroll down` Effect fields scale their positive
integer milliseconds-per-pixel delay. Direction, bounds and fade geometry stay
unchanged. Unknown effect names and zero/fractional legacy speed defaults are
refused for rate changes; a pure delay still preserves them. Integer speed
quantization and output-dependent native legacy-effect behavior remain renderer
limitations rather than pixel-parity guarantees.

Event times retain ASS centisecond resolution. Effect parameters retain their
native integer units. A transformed event must still have positive duration
after centisecond rounding. Wholly pre-zero cues use the existing omission
confirmation. A partially clipped event with timing tags or a legacy Effect is
refused: moving its visible start to zero would restart its relative animation
clock. Plain events can still be clipped as before.

Bounds: the existing 5 MiB input and 50000-event limits; 64 KiB per event text;
4096 override blocks, 8192 timed tags and 16 nested parentheses per event;
64 distinct event-format fields; signed 32-bit effect-time limits. Bad syntax,
nonfinite/oversized values and malformed arguments fail before any export write.

References: [Aegisub override tags](https://aegisub.org/docs/latest/ass_tags/)
and [libass parsing and karaoke clocks](https://github.com/libass/libass/blob/master/libass/ass_parse.c).
Confidence is moderate for source integration; renderer parity is unknown.
No tests, analyzers, builds, formatters or CI were run.
