import 'source_models.dart';

bool isPodcastEpisode(SourceEntry entry) =>
    !entry.isFolder && (entry.identifiers['podcast'] == 'episode' || entry.identifiers.containsKey('feed'));

DateTime? podcastPublishedAt(SourceEntry entry) {
  final milliseconds = int.tryParse(entry.identifiers['publishedAt'] ?? '');
  if (milliseconds != null && milliseconds.abs() <= 8640000000000000) {
    return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }
  return parsePodcastDate(entry.identifiers['published'] ?? '');
}

/// RSS uses RFC 822 dates; Atom uses ISO 8601. Never substitute the refresh
/// time for a missing/invalid publication date, which would reorder old shows.
DateTime? parsePodcastDate(String value) {
  final iso = DateTime.tryParse(value.trim());
  if (iso != null) return iso.toUtc();
  final match = RegExp(
    r'^(?:[A-Za-z]{3},?\s+)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{2,4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s+([+-]\d{4}|[A-Za-z]{1,5})(?:\s+\([^)]*\))?$',
  ).firstMatch(value.trim());
  if (match == null) return null;
  const months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
  final month = months.indexOf(match[2]!.toLowerCase()) + 1;
  var year = int.parse(match[3]!);
  if (year < 100) year += year < 50 ? 2000 : 1900;
  final day = int.parse(match[1]!), hour = int.parse(match[4]!), minute = int.parse(match[5]!);
  final second = int.parse(match[6] ?? '0');
  if (month == 0 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59) return null;
  final zone = match[7]!.toUpperCase();
  const zones = {
    'UT': 0,
    'UTC': 0,
    'GMT': 0,
    'Z': 0,
    'EST': -300,
    'EDT': -240,
    'CST': -360,
    'CDT': -300,
    'MST': -420,
    'MDT': -360,
    'PST': -480,
    'PDT': -420,
  };
  int? offset = zones[zone];
  if (offset == null && (zone.startsWith('+') || zone.startsWith('-'))) {
    final hours = int.parse(zone.substring(1, 3)), minutes = int.parse(zone.substring(3));
    if (hours > 23 || minutes > 59) return null;
    offset = (hours * 60 + minutes) * (zone.startsWith('-') ? -1 : 1);
  }
  if (offset == null) return null;
  final date = DateTime.utc(year, month, day, hour, minute, second);
  if (date.month != month || date.day != day) return null;
  return date.subtract(Duration(minutes: offset));
}

int? podcastTimestamp(String value) {
  final parts = value.trim().split(':');
  if (parts.isEmpty || parts.length > 3) return null;
  var seconds = 0.0;
  for (var index = 0; index < parts.length; index++) {
    final number = double.tryParse(parts[index]);
    if (number == null || !number.isFinite || number < 0 || (index > 0 && number >= 60)) return null;
    seconds = seconds * 60 + number;
  }
  return seconds > 7 * 24 * 3600 ? null : (seconds * 1000).round();
}

String podcastPlainText(String value) {
  final plain = value
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return plain.length > 8000 ? plain.substring(0, 8000) : plain;
}

List<BookChapter> podcastJsonChapters(Map<String, dynamic> data, {int? durationMs}) {
  final chapters = <BookChapter>[];
  final seen = <int>{};
  for (final value in sourceList(data['chapters']).take(2000)) {
    final item = sourceMap(value);
    final seconds = item['startTime'];
    if (seconds is! num || !seconds.isFinite || seconds < 0 || seconds > 7 * 24 * 3600) continue;
    final start = (seconds * 1000).round();
    if (durationMs != null && durationMs > 0 && start >= durationMs) continue;
    if (item['toc'] == false) continue;
    final title = podcastPlainText(item['title'] is String ? item['title'] as String : '');
    if (title.isEmpty || !seen.add(start)) continue;
    chapters.add(BookChapter(title: title, startMs: start, endMs: 0));
  }
  chapters.sort((a, b) => a.startMs.compareTo(b.startMs));
  return [
    for (var i = 0; i < chapters.length; i++)
      BookChapter(
        title: chapters[i].title,
        startMs: chapters[i].startMs,
        endMs: i + 1 < chapters.length ? chapters[i + 1].startMs : durationMs ?? 0,
      ),
  ];
}
