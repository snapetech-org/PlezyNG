# Editable text import

The transcript tools can preview a selected text subtitle's encoding and create
a separate reviewed UTF-8 SRT. The regular track picker, archive picker, drop
handler, and Android pending-share queue also offer these conversions when the
player accepts SRT but cannot render the input format directly. Native formats
continue through the existing player renderer. Conversion never rewrites the
original.

| Input | Conversion contract |
| --- | --- |
| SRT, WebVTT, ASS/SSA | Existing bounded cue parser; encoding override is available through the explicit preview action. ASS layout/animation remains in the original, not the SRT derivative. |
| TTML / DFXP / text IMSC | Media clock, parallel body/div/p/span containers, parent-relative begin/end/dur, frame/subframe/tick expressions, timed text spans, explicit line breaks and inherited whitespace. Overlapping paragraphs stay distinct. Regions, styling, ruby and writing modes are flattened with a warning. Sequential containers, images, external media, animation, DTD/entity declarations, non-media time bases and unbounded text durations are refused. This is not full TTML/IMSC conformance. |
| SAMI | Millisecond SYNC times, explicit class selection (first declared class by default), line breaks and basic/numeric HTML entities. Layout is flattened. Class choices are listed in the preview. |
| MicroDVD text SUB | Explicit source FPS or file header; no inference from movie FPS. Frame times convert to milliseconds. Inline style codes are removed. Bitmap SUB is refused. |
| SBV | Explicit start/end clock pairs and multiline text. |
| LRC | Repeated line timestamps, explicit offset, next timestamp as end. Enhanced word markers are flattened, not represented as verified word timings. |
| MPL2 | Decisecond start/end, line separators and per-line italic markers. |

SAMI/LRC without a final closing timestamp use the visible, editable final-cue
duration (100–30000 ms, initial value 2000 ms). The preview explains this
assumption. Sparse cues and overlaps are preserved; no missing speech is inferred.

Encoding is selected explicitly. Default Unicode accepts strict UTF-8 or
BOM-marked UTF-16. Overrides cover BOM-less UTF-16, Windows-1250–1258,
ISO-8859-1/2/5/6/7/8/9/15, KOI8-R/U, DOS-437/850/866, CP932/Shift-JIS, GBK,
GB18030, Big5 and CP949/UHC. Undefined/truncated sequences fail without
replacement characters. Hebrew visual-order rearrangement, EUC-JP and
Big5-HKSCS are not inferred or claimed. GB18030 uses the precise CPython mapping
recorded in the generated table header, not an assertion of every standard
revision's mapping.

`tools/generate_subtitle_codecs.py` produces the bundled compressed Unicode
mapping tables from CPython's standard-library codecs. Runtime decoding is Dart
and needs no Python, network, native codec SDK or extra package. Preview parsing
runs through Flutter compute. Bounds include 5 MiB input/decoded text, 50000
cues, 4000 characters per cue, 200000 XML events, 64-level nesting and a bounded
timed-span conversion work budget. Preview changes invalidate previously
accepted results. Native attachment checks the player's media generation again
after asynchronous conversion.

References: [TTML2](https://www.w3.org/TR/ttml2/),
[Dart XML](https://pub.dev/packages/xml),
[CPython codecs](https://docs.python.org/3/library/codecs.html).

No fixtures, analyzer, builds, device runs or CI were run for these changes, as
requested by the owner. UI controls and native attachment remain unqualified.
