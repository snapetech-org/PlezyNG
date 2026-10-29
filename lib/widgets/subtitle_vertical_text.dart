import 'dart:math' as math;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'subtitle_ruby_span.dart';

/// Bounded app typesetting: graphemes, styled sideways runs and adjacent ruby.
/// This does not emulate native ASS or OpenType vertical substitution tables.
class SubtitleVerticalText extends StatefulWidget {
  const SubtitleVerticalText({super.key, this.text, this.content, required this.style,
    required this.rightToLeft, required this.outline, required this.outlineWidth,
    this.maximumColumns = 6}) : assert(text != null || content != null);
  final String? text;
  final InlineSpan? content;
  final TextStyle style;
  final bool rightToLeft;
  final Color outline;
  final double outlineWidth;
  final int maximumColumns;
  @override
  State<SubtitleVerticalText> createState() => _SubtitleVerticalTextState();
}

class _Run {
  const _Run(this.text, this.style, {this.reading, this.base = const []});
  final String text;
  final TextStyle style;
  final String? reading;
  final List<_Run> base;
  @override
  bool operator ==(Object other) => other is _Run && text == other.text && style == other.style &&
      reading == other.reading && listEquals(base, other.base);
  @override
  int get hashCode => Object.hash(text, style, reading, Object.hashAll(base));
}

List<_Run> _runs(InlineSpan content, TextStyle initial) {
  final output = <_Run>[];
  var visited = 0;
  void visit(InlineSpan span, TextStyle inherited, int depth) {
    if (++visited > 1024 || depth > 16) return;
    if (span is SubtitleRubySpan) {
      final base = span.baseSpans == null ? <_Run>[_Run(span.base, inherited)]
          : _runs(TextSpan(children: span.baseSpans), inherited);
      output.add(_Run(span.base, inherited, reading: span.reading, base: base));
    } else if (span is TextSpan) {
      var style = inherited.merge(span.style);
      if (span.locale != null) style = style.copyWith(locale: span.locale);
      if (span.text?.isNotEmpty == true) output.add(_Run(span.text!, style));
      for (final child in span.children ?? const <InlineSpan>[]) { visit(child, style, depth + 1); }
    }
  }
  visit(content, initial, 0);
  return output;
}

class _SubtitleVerticalTextState extends State<SubtitleVerticalText> {
  _VerticalLayout? _layout;
  Object? _key;
  List<_Run> _previous = const [];
  @override
  void dispose() { _layout?.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final scaler = MediaQuery.textScalerOf(context);
    final em = scaler.scale(widget.style.fontSize ?? 30);
    final maxHeight = constraints.hasBoundedHeight ? constraints.maxHeight : em * 12;
    final maxWidth = constraints.hasBoundedWidth ? constraints.maxWidth : em * widget.maximumColumns * 1.95;
    if (maxHeight < em || maxWidth < em) return const SizedBox.shrink();
    final runs = _runs(widget.content ?? TextSpan(text: widget.text), widget.style);
    final key = (widget.style, widget.rightToLeft, widget.outline, widget.outlineWidth,
      widget.maximumColumns, maxHeight, maxWidth, scaler);
    if (_key != key || !listEquals(_previous, runs)) {
      _layout?.dispose(); _key = key; _previous = runs;
      _layout = _VerticalLayout(runs, widget.style, scaler, maxWidth, maxHeight,
        widget.maximumColumns, widget.rightToLeft, widget.outline, widget.outlineWidth);
    }
    final label = runs.map((run) => run.reading == null ? run.text : '${run.text} (${run.reading})').join();
    return Semantics(label: label, child: ExcludeSemantics(child: CustomPaint(
      size: _layout!.size, painter: _VerticalPainter(_layout!))));
  });
}

class _Token {
  const _Token(this.text, this.runs, [this.reading]);
  final String text;
  final List<_Run> runs;
  final String? reading;
}

List<_Token> _tokens(List<_Run> runs) {
  final output = <_Token>[];
  var consumed = 0;
  final pending = <_Run>[];
  List<_Run> slice(List<_Run> values, int from, int until) {
    final result = <_Run>[];
    var cursor = 0;
    for (final run in values) {
      final lo = math.max(cursor, from), hi = math.min(cursor + run.text.length, until);
      if (hi > lo) result.add(_Run(run.text.substring(lo - cursor, hi - cursor), run.style));
      cursor += run.text.length;
      if (cursor >= until) break;
    }
    return result;
  }
  void flush() {
    if (pending.isEmpty) return;
    final text = pending.map((run) => run.text).join();
    var cursor = 0, start = 0, length = 0;
    void emit(int end) {
      if (end > start) output.add(_Token(text.substring(start, end), slice(pending, start, end)));
      start = end; length = 0;
    }
    // Segment the complete text before slicing styles, so a style boundary
    // cannot split a combining sequence or an emoji grapheme.
    for (final cluster in text.characters) {
      if (++consumed > 512) { emit(cursor); output.add(_Token('…', [_Run('…', pending.last.style)])); break; }
      final rune = cluster.runes.first;
      final upright = rune >= 0x2e80 && rune <= 0xa4cf || rune >= 0xac00 && rune <= 0xd7af ||
          rune >= 0xf900 && rune <= 0xfaff || rune >= 0xfe10 && rune <= 0xfe6f ||
          rune >= 0xff01 && rune <= 0xff60 || rune >= 0x1f000;
      if (cluster == '\n' || cluster.trim().isEmpty || upright) {
        emit(cursor); cursor += cluster.length; emit(cursor);
      } else {
        cursor += cluster.length;
        if (++length >= 32) emit(cursor);
      }
    }
    if (consumed <= 512) emit(cursor);
    pending.clear();
  }
  for (final run in runs) {
    if (consumed > 512) break;
    if (run.reading == null) { pending.add(run); continue; }
    flush();
    if (consumed > 512) break;
    final count = run.text.characters.length;
    if (consumed + count > 512) { output.add(_Token('…', [_Run('…', run.style)])); consumed = 513; break; }
    consumed += count;
    output.add(_Token(run.text, run.base.isEmpty ? [_Run(run.text, run.style)] : run.base, run.reading));
  }
  if (consumed <= 512) flush();
  return output;
}

class _VerticalCell {
  _VerticalCell(this.column, this.y, this.advance, {this.fill, this.stroke,
    this.rotate = false, this.combine = false, this.base, this.reading});
  final TextPainter? fill, stroke;
  final _VerticalLayout? base, reading;
  final int column;
  final double y, advance;
  final bool rotate, combine;
  void dispose() { fill?.dispose(); stroke?.dispose(); base?.dispose(); reading?.dispose(); }
}

class _VerticalLayout {
  _VerticalLayout(List<_Run> runs, TextStyle style, TextScaler scaler, double width, double height,
      int maximumColumns, this.rtl, Color outline, double outlineWidth) {
    final em = scaler.scale(style.fontSize ?? 30);
    final tokens = _tokens(runs);
    final hasRuby = tokens.any((token) => token.reading != null);
    baseWidth = em * 1.3;
    final annotationSize = (style.fontSize ?? 30) * .5;
    columnWidth = baseWidth + (hasRuby ? scaler.scale(annotationSize) * 1.3 : 0);
    final columns = (width / columnWidth).floor().clamp(1, math.max(1, maximumColumns)).toInt();
    var column = 0, y = 0.0, maxY = 0.0, truncated = false;
    const punctuation = {'（': '︵', '）': '︶', '［': '﹇', '］': '﹈', '｛': '︷', '｝': '︸',
      '「': '﹁', '」': '﹂', '『': '﹃', '』': '﹄', '【': '︻', '】': '︼', '…': '︙', '—': '︱'};
    for (final token in tokens) {
      if (token.text == '\n') {
        maxY = math.max(maxY, y); y = 0; column++;
        if (column >= columns) { truncated = true; break; }
        continue;
      }
      if (token.text.isEmpty) continue;
      final rune = token.text.runes.first;
      final rotate = !punctuation.containsKey(token.text) && rune < 0x2e80 && token.text.trim().isNotEmpty;
      final combine = RegExp(r'^\d{1,2}$').hasMatch(token.text);
      TextPainter painter(bool stroke) => TextPainter(text: TextSpan(children: [
        for (final run in punctuation.containsKey(token.text)
            ? [_Run(punctuation[token.text]!, token.runs.first.style)] : token.runs)
          TextSpan(text: run.text, locale: run.style.locale, style: stroke
            ? run.style.copyWith(height: 1, backgroundColor: Colors.transparent, foreground:
              Paint()..style = PaintingStyle.stroke..strokeWidth = outlineWidth * 2..color = outline)
            : run.style.copyWith(height: 1)),
      ]), textScaler: scaler, textDirection: RegExp(r'[\u0590-\u08ff]').hasMatch(token.text)
          ? TextDirection.rtl : TextDirection.ltr, maxLines: 1, ellipsis: '…')
        ..layout(maxWidth: rotate && !combine ? height : em * 2);
      final fill = token.reading == null ? painter(false) : null;
      final stroke = token.reading == null && outlineWidth > 0 ? painter(true) : null;
      final base = token.reading == null ? null : _VerticalLayout(token.runs, style, scaler,
        baseWidth, height, 1, rtl, outline, outlineWidth);
      final readingStyle = style.copyWith(fontSize: annotationSize,
        locale: token.runs.first.style.locale);
      final reading = token.reading == null ? null : _VerticalLayout([_Run(token.reading!, readingStyle)],
        readingStyle, scaler, columnWidth - baseWidth, height, 1, rtl, outline, outlineWidth * .5);
      final advance = base != null ? math.max(base.size.height, reading!.size.height)
          : rotate && !combine ? math.max(em, fill!.width) : em * 1.15;
      if (y + advance > height && y > 0) { maxY = math.max(maxY, y); y = 0; column++; }
      final cell = _VerticalCell(column, y, advance, fill: fill, stroke: stroke, rotate: rotate,
        combine: combine, base: base, reading: reading);
      if (column >= columns) { cell.dispose(); truncated = true; break; }
      cells.add(cell); y += advance;
    }
    maxY = math.max(maxY, y);
    if (truncated && cells.isNotEmpty) {
      final last = cells.removeLast();
      final ellipsis = TextPainter(text: TextSpan(text: '︙', style: style), textScaler: scaler,
        textDirection: TextDirection.ltr)..layout();
      cells.add(_VerticalCell(last.column, last.y, math.min(last.advance, em * 1.15), fill: ellipsis));
      last.dispose();
    }
    count = cells.isEmpty ? 1 : cells.last.column + 1;
    size = Size(math.min(width, count * columnWidth), math.min(height, math.max(em, maxY)));
  }
  final List<_VerticalCell> cells = [];
  late final Size size;
  late final double columnWidth, baseWidth;
  late final int count;
  final bool rtl;
  void dispose() { for (final cell in cells) { cell.dispose(); } }
  void paint(Canvas canvas) {
    canvas.save(); canvas.clipRect(Offset.zero & size);
    for (final cell in cells) {
      final x = (rtl ? count - cell.column - 1 : cell.column) * columnWidth;
      canvas.save();
      if (cell.base case final _VerticalLayout base) {
        canvas.translate(x, cell.y + (cell.advance - base.size.height) / 2); base.paint(canvas);
        canvas.restore(); canvas.save();
        final reading = cell.reading!;
        // Annotation sits to the right of the base in either column order.
        canvas.translate(x + baseWidth, cell.y + (cell.advance - reading.size.height) / 2);
        reading.paint(canvas);
      } else {
        final fill = cell.fill!;
        if (cell.rotate && !cell.combine) {
          canvas.translate(x + (baseWidth + fill.height) / 2, cell.y); canvas.rotate(math.pi / 2);
        } else {
          canvas.translate(x + baseWidth / 2, cell.y + cell.advance / 2);
          final scale = cell.combine ? math.min(1.0, baseWidth * .9 / math.max(1, fill.width)) : 1.0;
          canvas.scale(scale); canvas.translate(-fill.width / 2, -fill.height / 2);
        }
        cell.stroke?.paint(canvas, Offset.zero); fill.paint(canvas, Offset.zero);
      }
      canvas.restore();
    }
    canvas.restore();
  }
}

class _VerticalPainter extends CustomPainter {
  const _VerticalPainter(this.layout);
  final _VerticalLayout layout;
  @override
  void paint(Canvas canvas, Size size) => layout.paint(canvas);
  @override
  bool shouldRepaint(_VerticalPainter oldDelegate) => oldDelegate.layout != layout;
}
