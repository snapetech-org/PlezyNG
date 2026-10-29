/// Bounded WebVTT/HTML ruby subset. Unsupported or malformed markup falls back
/// to readable base text; it is never interpreted as executable HTML.
class SubtitleRubyRun {
  const SubtitleRubyRun(this.base, [this.reading]);
  final String base;
  final String? reading;
}

abstract final class SubtitleRubyText {
  static final _ruby = RegExp(r'<ruby\s*>([\s\S]*?)</ruby\s*>', caseSensitive: false);
  static final _reading = RegExp(r'<rt\s*>([\s\S]*?)</rt\s*>', caseSensitive: false);
  static final _parentheses = RegExp(r'<rp\s*>[\s\S]*?</rp\s*>', caseSensitive: false);
  static String baseText(String text) => text.replaceAll(_reading, '').replaceAll(_parentheses, '');
  static String plain(String text) => baseText(text).replaceAll(RegExp(r'<[^>]*>|\{[^}]*\}'), '')
      .replaceAll(r'\N', '\n').replaceAll('&lt;', '<').replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"').replaceAll('&#39;', "'").replaceAll('&nbsp;', ' ').replaceAll('&amp;', '&');

  static List<SubtitleRubyRun>? parse(String text) {
    if (text.length > 4000 || !text.toLowerCase().contains('<ruby')) return null;
    final result = <SubtitleRubyRun>[];
    var cursor = 0, annotations = 0;
    for (final match in _ruby.allMatches(text)) {
      if (match.start > cursor) result.add(SubtitleRubyRun(plain(text.substring(cursor, match.start))));
      final content = match[1]!.replaceAll(_parentheses, '').replaceAll(RegExp(r'</?rb\s*>', caseSensitive: false), '');
      if (content.toLowerCase().contains('<ruby')) return null;
      var offset = 0;
      for (final reading in _reading.allMatches(content)) {
        final base = plain(content.substring(offset, reading.start)), annotation = plain(reading[1]!);
        if (base.isEmpty || base.runes.length > 64 || annotation.isEmpty || annotation.runes.length > 128 ||
            base.contains('\n') || annotation.contains('\n') || ++annotations > 32) return null;
        result.add(SubtitleRubyRun(base, annotation)); offset = reading.end;
      }
      if (offset < content.length) result.add(SubtitleRubyRun(plain(content.substring(offset))));
      cursor = match.end;
    }
    if (annotations == 0) return null;
    if (cursor < text.length) result.add(SubtitleRubyRun(plain(text.substring(cursor))));
    return List.unmodifiable(result);
  }
}
