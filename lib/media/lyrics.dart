/// A source-timed lyric unit. Missing end times are retained, never presented
/// as measured syllable durations. Text includes its original whitespace.
enum LyricUnit { word, syllable, token }

class LyricSpan {
  final String text;
  final int startMs;
  final int? endMs;
  final LyricUnit unit;
  final String? part;
  final double? confidence;

  const LyricSpan({required this.text, required this.startMs, this.endMs, this.unit = LyricUnit.word, this.part, this.confidence});

  Map<String, dynamic> toJson() => {
    'text': text, 'startMs': startMs, if (endMs != null) 'endMs': endMs,
    'unit': unit.name, if (part != null) 'part': part, if(confidence!=null)'confidence':confidence,
  };

  factory LyricSpan.fromJson(Map<String, dynamic> json) => LyricSpan(
    text: json['text'] as String, startMs: json['startMs'] as int,
    endMs: json['endMs'] as int?, part: json['part'] as String?, confidence:(json['confidence'] as num?)?.toDouble(),
    unit: LyricUnit.values.firstWhere((u) => u.name == json['unit'], orElse: () => LyricUnit.word),
  );
}

/// One lyric line. [startMs] is the offset from track start, `null` when the
/// source is unsynced plain text.
class LyricLine {
  final String text;
  final int? startMs;
  final int? endMs;
  final String? part;
  final String? translation;
  final String? pronunciation;
  final List<LyricSpan> spans;

  const LyricLine({required this.text, this.startMs, this.endMs, this.part,
    this.translation, this.pronunciation, this.spans = const []});

  Map<String, dynamic> toJson() => {
    'text': text, if (startMs != null) 'startMs': startMs, if (endMs != null) 'endMs': endMs,
    if (part != null) 'part': part, if (translation != null) 'translation': translation,
    if (pronunciation != null) 'pronunciation': pronunciation,
    if (spans.isNotEmpty) 'spans': spans.map((s) => s.toJson()).toList(),
  };

  factory LyricLine.fromJson(Map<String, dynamic> json) => LyricLine(
    text: json['text'] as String, startMs: json['startMs'] as int?, endMs: json['endMs'] as int?,
    part: json['part'] as String?, translation: json['translation'] as String?,
    pronunciation: json['pronunciation'] as String?,
    spans: List.unmodifiable((json['spans'] as List? ?? const []).map((s) => LyricSpan.fromJson(Map<String, dynamic>.from(s as Map)))),
  );
}

/// Track lyrics as returned by [MediaServerClient.fetchLyrics].
///
/// [synced] is true when (enough) lines carry [LyricLine.startMs] for the
/// player to highlight/scroll along with playback. Jellyfin's `LyricDto`
/// omits its `IsSynced` flag on some server versions, so implementations
/// infer synced-ness from the presence of per-line offsets.
class Lyrics {
  final bool synced;
  final List<LyricLine> lines;

  const Lyrics({required this.synced, required this.lines});

  bool get isEmpty => lines.isEmpty;

  Map<String, dynamic> toJson() => {'synced': synced, 'lines': lines.map((l) => l.toJson()).toList()};

  factory Lyrics.fromJson(Map<String, dynamic> json) => Lyrics(
    synced: json['synced'] == true,
    lines: List.unmodifiable((json['lines'] as List).map((l) => LyricLine.fromJson(Map<String, dynamic>.from(l as Map)))),
  );
}
