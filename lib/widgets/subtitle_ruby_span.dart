import 'package:flutter/material.dart';

/// Horizontal ruby keeps a base/reading pair together when wrapping. The
/// enclosing caption supplies the same font, scale and stroke to both layers.
/// This does not emulate vertical OpenType shaping or native ASS layout.
class SubtitleRubySpan extends WidgetSpan {
  SubtitleRubySpan(this.base, this.reading, {this.baseSpans})
      : super(alignment: PlaceholderAlignment.bottom, child: _Ruby(base, reading, baseSpans));
  final String base, reading;
  final List<InlineSpan>? baseSpans;
}

class _Ruby extends StatelessWidget {
  const _Ruby(this.base, this.reading, this.baseSpans);
  final String base, reading;
  final List<InlineSpan>? baseSpans;
  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    final locale = baseSpans?.whereType<TextSpan>().firstOrNull?.locale;
    return Semantics(label: '$base ($reading)', child: ExcludeSemantics(child: FittedBox(
      fit: BoxFit.scaleDown, alignment: Alignment.bottomCenter,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(reading, locale: locale, style: style.copyWith(fontSize: (style.fontSize ?? 30) * .5, height: 1.05),
          textAlign: TextAlign.center, softWrap: false, maxLines: 1),
        Text.rich(TextSpan(text: baseSpans == null ? base : null, children: baseSpans),
          style: style.copyWith(height: 1.15), textAlign: TextAlign.center, softWrap: false, maxLines: 1),
      ]))));
  }
}
