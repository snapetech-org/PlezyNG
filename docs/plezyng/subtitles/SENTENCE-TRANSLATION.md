# Sentence-context translation

The local ML Kit/Argos translation flow offers an explicit sentence-context
switch. It groups at most six adjacent plain-text cues across gaps no longer
than 350 ms, with a twelve-second span and 2400-character source limit. Sentence
endings, speaker labels, dialogue dashes, markup, music markers and overlaps
separate groups. Original cue IDs, indexes and start/end times remain unchanged.

Translation runs on the grouped text. A conservative duration-weighted layout
then divides its output only at whitespace or selected CJK punctuation. Glossary
phrases and numeric expressions stay together. Each fragment must be nonempty
and fit the viewer's 5–60 Unicode-code-point-per-second limit. Groups that cannot
be divided safely are translated again cue by cue; those fallback cues are not
claimed to satisfy the reading limit. Unspaced scripts without usable boundaries
also fall back. This is approximate text placement, not forced alignment.

The normal before/after review, editing and separate revision path remains
mandatory. A warning reports redistributed groups and fallback cue counts.
Bilingual output is composed from each original cue after distribution; its
combined source/target reading rate is not measured. Reviewed translation memory
is disabled in this mode because grouped context changes its cache identity.
Authored ASS layout continues through the native renderer; this derivative is
plain SRT. Source and output caps remain 50,000 cues / 5 MiB / 4000 characters per
cue, including bilingual text.

No translation model, fixture, analyzer, build or test was run. Linguistic
quality, timing readability, and platform behavior remain unqualified.
