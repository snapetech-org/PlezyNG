import 'dart:math' as math;
import 'package:flutter/material.dart';

/// A bounded vertical text lane. Grapheme clusters stay intact; non-CJK runs
/// retain horizontal shaping and rotate as a unit. This does not implement
/// native ASS typesetting or OpenType vertical substitution tables.
class SubtitleVerticalText extends StatefulWidget {
  const SubtitleVerticalText({super.key, required this.text, required this.style,
    required this.rightToLeft, required this.outline, required this.outlineWidth,
    this.maximumColumns = 6});
  final String text;
  final TextStyle style;
  final bool rightToLeft;
  final Color outline;
  final double outlineWidth;
  final int maximumColumns;
  @override
  State<SubtitleVerticalText> createState() => _SubtitleVerticalTextState();
}

class _SubtitleVerticalTextState extends State<SubtitleVerticalText> {
  _VerticalLayout? _layout;
  Object? _key;
  @override
  void dispose() { _layout?.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final scaler = MediaQuery.textScalerOf(context);
    final em = scaler.scale(widget.style.fontSize ?? 30);
    final maxHeight = constraints.hasBoundedHeight ? constraints.maxHeight : em * 12;
    final maxWidth = constraints.hasBoundedWidth ? constraints.maxWidth : em * widget.maximumColumns * 1.25;
    if (maxHeight < em || maxWidth < em) return const SizedBox.shrink();
    final key = (widget.text, widget.style, widget.rightToLeft, widget.outline,
      widget.outlineWidth, widget.maximumColumns, maxHeight, maxWidth, scaler);
    if (_key != key) {
      _layout?.dispose(); _key = key;
      _layout = _VerticalLayout(widget, scaler, maxWidth, maxHeight);
    }
    return Semantics(label: widget.text, child: ExcludeSemantics(child: CustomPaint(
      size: _layout!.size, painter: _VerticalPainter(_layout!))));
  });
}

class _VerticalCell {
  _VerticalCell(this.fill, this.stroke, this.column, this.y, this.advance, this.rotate, this.combine);
  final TextPainter fill;
  final TextPainter? stroke;
  final int column;
  final double y, advance;
  final bool rotate, combine;
  void dispose() { fill.dispose(); stroke?.dispose(); }
}

class _VerticalLayout {
  _VerticalLayout(SubtitleVerticalText widget, TextScaler scaler, double width, double height) {
    final em = scaler.scale(widget.style.fontSize ?? 30);
    columnWidth = em * 1.3;
    rtl = widget.rightToLeft;
    final columns = (width / columnWidth).floor().clamp(1, widget.maximumColumns).toInt();
    var column = 0, y = 0.0, maxY = 0.0;
    final tokens = <String>[];
    var run = '';
    void flush() { if (run.isNotEmpty) { tokens.add(run); run = ''; } }
    var consumed = 0;
    for (final cluster in widget.text.characters) {
      if (++consumed > 512) { flush(); tokens.add('…'); break; }
      final rune = cluster.runes.first;
      final upright = rune >= 0x2e80 && rune <= 0xa4cf || rune >= 0xac00 && rune <= 0xd7af ||
          rune >= 0xf900 && rune <= 0xfaff || rune >= 0xfe10 && rune <= 0xfe6f ||
          rune >= 0xff01 && rune <= 0xff60 || rune >= 0x1f000;
      if (cluster == '\n' || cluster.trim().isEmpty || upright) { flush(); tokens.add(cluster); }
      else { run += cluster; if (run.length >= 32) flush(); }
    }
    flush();
    const punctuation = {'（': '︵', '）': '︶', '［': '﹇', '］': '﹈', '｛': '︷', '｝': '︸',
      '「': '﹁', '」': '﹂', '『': '﹃', '』': '﹄', '【': '︻', '】': '︼', '…': '︙', '—': '︱'};
    var truncated = false;
    for (var index = 0; index < tokens.length; index++) {
      var token = tokens[index];
      if (token == '\n') { maxY = math.max(maxY, y); y = 0; column++; if (column >= columns) { truncated = true; break; } continue; }
      final rune = token.runes.first;
      final rotate = !punctuation.containsKey(token) && rune < 0x2e80 && token.trim().isNotEmpty;
      final combine = RegExp(r'^\d{1,2}$').hasMatch(token);
      token = punctuation[token] ?? token;
      TextPainter painter(TextStyle style) => TextPainter(text: TextSpan(text: token, style: style),
        textScaler: scaler, textDirection: RegExp(r'[\u0590-\u08ff]').hasMatch(token) ? TextDirection.rtl : TextDirection.ltr,
        maxLines: 1, ellipsis: '…')..layout(maxWidth: rotate && !combine ? height : em * 2);
      final fill = painter(widget.style.copyWith(height: 1));
      final stroke = widget.outlineWidth > 0 ? painter(widget.style.copyWith(height: 1, foreground:
        Paint()..style = PaintingStyle.stroke..strokeWidth = widget.outlineWidth * 2..color = widget.outline)) : null;
      final advance = rotate && !combine ? math.max(em, fill.width) : em * 1.15;
      if (y + advance > height && y > 0) { maxY = math.max(maxY, y); y = 0; column++; }
      if (column >= columns) { fill.dispose(); stroke?.dispose(); truncated = true; break; }
      cells.add(_VerticalCell(fill, stroke, column, y, advance, rotate, combine));
      y += advance;
    }
    maxY = math.max(maxY, y);
    if (truncated && cells.isNotEmpty) {
      final last = cells.removeLast();
      final ellipsis = TextPainter(text: TextSpan(text: '︙', style: widget.style), textScaler: scaler,
        textDirection: TextDirection.ltr)..layout();
      cells.add(_VerticalCell(ellipsis, null, last.column, last.y, last.advance, false, false));
      last.dispose();
    }
    count = cells.isEmpty ? 1 : cells.last.column + 1;
    size = Size(math.min(width, count * columnWidth), math.min(height, math.max(em, maxY)));
  }
  final List<_VerticalCell> cells = [];
  late final Size size;
  late final double columnWidth;
  late final int count;
  late final bool rtl;
  void dispose() { for (final cell in cells) { cell.dispose(); } }
}

class _VerticalPainter extends CustomPainter {
  const _VerticalPainter(this.layout);
  final _VerticalLayout layout;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save(); canvas.clipRect(Offset.zero & size);
    for (final cell in layout.cells) {
      final x = (layout.rtl ? layout.count - cell.column - 1 : cell.column) * layout.columnWidth;
      canvas.save();
      if (cell.rotate && !cell.combine) {
        canvas.translate(x + (layout.columnWidth + cell.fill.height) / 2, cell.y);
        canvas.rotate(math.pi / 2);
      } else {
        canvas.translate(x + layout.columnWidth / 2, cell.y + cell.advance / 2);
        final scale = cell.combine ? math.min(1.0, layout.columnWidth * .9 / math.max(1, cell.fill.width)) : 1.0;
        canvas.scale(scale);
        canvas.translate(-cell.fill.width / 2, -cell.fill.height / 2);
      }
      cell.stroke?.paint(canvas, Offset.zero); cell.fill.paint(canvas, Offset.zero);
      canvas.restore();
    }
    canvas.restore();
  }
  @override
  bool shouldRepaint(_VerticalPainter oldDelegate) => oldDelegate.layout != layout;
}
