# Mixed-language cue annotations

The cue editor can wrap selected plain-text words with a WebVTT language span,
for example `<lang ja>日本語</lang>`. The helper requires complete grapheme
selections and refuses existing markup; additional balanced tags can be edited
directly. Supported tags are a bounded `language[-Script][-REGION]` subset with
two/three-letter language codes, optional four-letter script and optional
two-letter or three-digit region. Registry validity and actual language are not
inferred. The track's overall language is unchanged.

The annotation button, dialog, guidance and validation messages use the app's
centralized Slang strings with an explicit English fallback. No translator
review has been recorded yet.

The parser limits a cue to 4000 characters, 256 markup tokens, 64 annotations and
eight nested language levels. Unsupported/malformed annotations fall back to
readable plain text in the overlay. Horizontal text spans carry both glyph
locale and accessibility locale; retained word highlights can cross language
boundaries without rewriting the cue or inventing timestamps. Review retains
existing word timings after annotation-only edits with unchanged cue times and
spoken text; changed words or times still invalidate them. Where language
annotations and ruby coexist, the annotated base text is shown without ruby
readings. Vertical spans retain plain text and do not claim locale-aware native
vertical shaping.

Canonical cue text carries tags through JSON revisions, undo, download retention
and encrypted caption exchange. Shared WebVTT emits escaped text and supported
language tags only. SRT export removes supported language tags, and native
snapshot export retains its explicit plain-text flattening. Local and companion
translation remove source-language labels from translated words; bilingual
local output may still retain the annotated original line. Translation continues
to use its explicitly selected source/target pair, not per-span model switching.
Device speech output also retains its existing explicit voice behavior.

Semantics follow [WebVTT language spans](https://www.w3.org/TR/webvtt1/#webvtt-cue-language-span)
and Flutter's [TextSpan locale](https://api.flutter.dev/flutter/painting/TextSpan/locale.html)
and [TextStyle locale](https://api.flutter.dev/flutter/painting/TextStyle/locale.html).
Implementation confidence is moderate. No tests, analyzers, builds, screen-reader
or font execution, language-quality evaluation or CI ran. Automated code-switch
recognition and qualified pronunciation/typography remain open.
