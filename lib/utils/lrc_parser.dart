import '../media/lyrics.dart';

/// Matches `[mm:ss]`, `[mm:ss.x]`, `[mm:ss.xx]`, `[mm:ss.xxx]` timestamps
/// (multiple per line allowed, per the LRC spec).
final RegExp _timestamp = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:\.(\d{1,3}))?\]');

/// Metadata/ID tags like `[ar:Artist]`, `[offset:+120]`.
final RegExp _idTag = RegExp(r'^\[([a-zA-Z#]+):(.*)\]$');
final RegExp _wordTimestamp = RegExp(r'<(\d{1,3}):(\d{1,2})(?:\.(\d{1,3}))?>');

/// Parse LRC content into [Lyrics]. Lines with `[mm:ss.xx]` timestamps become
/// synced lines (a line with multiple timestamps is emitted once per
/// timestamp); the `[offset:±ms]` tag is applied. Input with no timestamps at
/// all falls back to unsynced plain text. Returns `null` for blank input.
Lyrics? parseLrc(String raw) {
  final lines = <LyricLine>[];
  final plain = <String>[];
  var offsetMs = 0;

  for (final rawLine in raw.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    final idTag = _idTag.firstMatch(line);
    if (idTag != null && !_timestamp.hasMatch(line)) {
      if (idTag.group(1)!.toLowerCase() == 'offset') {
        offsetMs = int.tryParse(idTag.group(2)!.trim()) ?? 0;
      }
      continue;
    }

    final stamps = _timestamp.allMatches(line).toList();
    if (stamps.isEmpty) {
      plain.add(line);
      continue;
    }

    final text = line.substring(stamps.last.end).trim();
    for (final m in stamps) {
      final minutes = int.parse(m.group(1)!);
      final seconds = int.parse(m.group(2)!);
      // Fractional part scales by digit count: ".5" = 500ms, ".50" = 500ms.
      final frac = m.group(3);
      final fracMs = frac == null ? 0 : (int.parse(frac) * 1000 ~/ _pow10(frac.length)).clamp(0, 999);
      final startMs = (minutes * 60 + seconds) * 1000 + fracMs - offsetMs;
      final marks = _wordTimestamp.allMatches(text).toList();
      final spans = <LyricSpan>[];
      final plain = StringBuffer();
      if (marks.isNotEmpty && marks.first.start > 0) plain.write(text.substring(0, marks.first.start));
      int wordTime(RegExpMatch mark) {
        final fraction = mark.group(3);
        return ((int.parse(mark.group(1)!) * 60 + int.parse(mark.group(2)!)) * 1000 +
          (fraction == null ? 0 : int.parse(fraction) * 1000 ~/ _pow10(fraction.length)) - offsetMs).clamp(0, 1 << 52);
      }
      for (var i = 0; i < marks.length; i++) {
        final unitText = text.substring(marks[i].end, i + 1 < marks.length ? marks[i + 1].start : text.length);
        plain.write(unitText);
        if (unitText.isNotEmpty) spans.add(LyricSpan(text: unitText, startMs: wordTime(marks[i]),
          endMs: i + 1 < marks.length ? wordTime(marks[i + 1]) : null));
      }
      lines.add(LyricLine(text: marks.isEmpty ? text : plain.toString().trim(),
        startMs: startMs < 0 ? 0 : startMs, spans: List.unmodifiable(spans)));
    }
  }

  if (lines.isNotEmpty) {
    lines.sort((a, b) => a.startMs!.compareTo(b.startMs!));
    return Lyrics(synced: true, lines: lines);
  }
  if (plain.isNotEmpty) {
    return Lyrics(synced: false, lines: [for (final t in plain) LyricLine(text: t)]);
  }
  return null;
}

int _pow10(int n) => switch (n) {
  1 => 10,
  2 => 100,
  _ => 1000,
};
