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
| SCC | Explicit channel within the supplied field, 30000/1001 or 30 fps, validated drop/non-drop timecode and optional clock-origin subtraction. Odd parity, frame-ordered byte pairs, pop-on memory swaps, paint-on updates and 2/3/4-row roll-up produce text-screen snapshots. Positions/styles are flattened; XDS, TEXT and 708 are refused. |

SCC's generated SRT keeps literal caption characters entity-escaped so they are
not interpreted as authored subtitle markup. The review preview decodes those
entities for display; the original SCC remains unchanged.

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

## SCC clocks and source-folder conversion

SCC timecodes describe transmission: each byte pair advances one frame. The
semicolon drop-frame clock excludes frame labels 00/01 at the start of each
minute except multiples of ten; these invalid labels and mixed clocks are
refused. A colon does not identify playback rate by itself, so the preview
exposes 30000/1001 (initial) or 30 fps. The clock-origin field subtracts elapsed
milliseconds after conversion; no first-caption or one-hour origin is guessed.
For example a 01:00:00:00 non-drop label at 30000/1001 is 3603600 elapsed ms.
Negative-origin preroll updates memory but only visible time at/after zero is
exported. Final visible text without a clear uses the selected tail duration.

Two 15x32 memories and their cursors retain loading/displayed state. Repeated
control transmissions are suppressed. CC1/CC2 selection changes only on a
recognized control pair; PAC/address and character bytes cannot switch the
active channel. Non-caption services and unsupported pairs fail explicitly.
The conversion bounds packets (500000), source lines
(32768 characters), resulting text (5 MiB), and snapshots (50000). Rapid paint-on
updates can therefore reach the output limit before a long program ends. This
editable text derivative preserves display changes but is not a native caption
service, a 608 styling engine, or a full conformance claim. Originals stay intact.

Source-folder discovery also offers supported editable text formats through the
existing local, network and cloud adapters. A non-native format, or a native text
format unsupported by the selected backend, must pass the same preview before
SRT attachment. Profile/player/source/part identity is checked after the source
read and after review. Bitmap SUB fails text decoding and keeps its OCR path;
archives still use explicit import. Source metadata may include unrelated XML
with a matching stem; the preview validates its actual format.

Behavior references: [Android caption memory implementation](https://android.googlesource.com/platform/frameworks/support/+/0a1194b22e9eb22b9991f13dbdb7632576b6baea/media2/media2-widget/src/main/java/androidx/media2/widget/Cea608CCParser.java),
[Media3 CEA package](https://developer.android.com/reference/androidx/media3/extractor/text/cea/package-summary),
and [FFmpeg timecode handling](https://github.com/FFmpeg/FFmpeg/blob/master/libavutil/timecode.c).
Confidence: moderate in inspected source behavior; parser conformance and target
playback remain unqualified. Tests, analyzers, formatters, builds and CI skipped.
