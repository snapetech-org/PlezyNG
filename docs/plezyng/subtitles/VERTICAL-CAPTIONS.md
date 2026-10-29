# Styled vertical captions

Source implementation, October 29, 2026. Confidence: moderate for the source
contract; unknown for device rendering and language typography. No tests,
analyzers, builds, font execution or CI ran, per owner instruction.

App overlay lanes now retain language-localized spans, original word highlights
and bounded ruby base/reading pairs in both vertical column orders. Plain text
is segmented into complete graphemes before styles are sliced. CJK-like glyphs
stay upright; other bounded runs keep horizontal shaping and rotate together.
One- and two-digit runs keep the existing upright combination behavior.

Ruby bases keep their original word colors and language spans. Readings occupy
a separate smaller column to the right of their base, with independent text
scaling and inherited language locale. The pair stays together when the outer
column wraps. Base and annotation are centered against the longer height; this
does not implement ruby overhang or distributed annotation spacing. The same
base spans now retain word highlighting and language selection in horizontal
ruby. Missing or mismatched token text still disables inferred highlighting.

The renderer caps base text at 512 graphemes, sideways runs at 32 graphemes,
ordinary display at six columns, and focused compact panes at three. Parsed
ruby remains limited to 32 pairs with at most 64 base and 128 reading code
points per pair. Column/height exhaustion produces an ellipsis; a viewport too
small for the requested glyph size can still clip. Captions and exports remain
unchanged. The accessibility label preserves the base and its reading.

Text painters are retained while text, language, paint style, dimensions and
accessibility scaling are unchanged, then disposed on replacement or widget
disposal. The path does not execute HTML, load external fonts from markup,
infer languages, invent timings, or replace the native ASS/bitmap renderer.
Full OpenType vertical substitutions, complete line-breaking/kinsoku rules,
native closed-caption presentation and visual/device qualification remain open.

Primary API/layout references:

- [Flutter TextPainter](https://api.flutter.dev/flutter/painting/TextPainter-class.html)
- [Flutter TextScaler](https://api.flutter.dev/flutter/painting/TextPainter/textScaler.html)
- [W3C ruby positioning](https://www.w3.org/TR/css-ruby-1/#ruby-position)
