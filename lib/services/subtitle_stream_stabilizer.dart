import 'dart:math' as math;
import 'subtitle_retimer.dart';
import 'subtitle_word_timing.dart';

final class SubtitleStableUpdate {
  const SubtitleStableUpdate(this.cues, this.words, this.preview, this.boundaryFinalized);
  final List<SubtitleCue> cues;
  final List<SubtitleWordTiming> words;
  final String? preview;
  /// A pause/stop/bounded-window flush has only one observation of its tail.
  final bool boundaryFinalized;
}

final class _SpeechUnit {
  const _SpeechUnit(this.start, this.end, this.text, this.word);
  final int start, end;
  final String text;
  final SubtitleWordTiming? word;
  String get normalized => text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  _SpeechUnit shifted(int delta) => _SpeechUnit(start + delta, end + delta, text, word == null ? null :
    SubtitleWordTiming(startMs: word!.startMs + delta, endMs: word!.endMs + delta, text: word!.text,
      confidence: word!.confidence, unit: word!.unit));
}

/// Local agreement over successive overlapping ASR passes. A shared prefix is
/// frozen only after two observations agree on text and source time. Agreement
/// is a display-stability heuristic, not recognition confidence. Original ASR
/// word/token clocks are retained; no evenly spaced timestamps are invented.
final class SubtitleStreamStabilizer {
  List<_SpeechUnit> _previous = const [];
  int committedThroughMs = -1;

  void reset() { _previous = const []; committedThroughMs = -1; }
  void rebase(int delta) {
    if (committedThroughMs >= 0) committedThroughMs += delta;
    _previous = _previous.map((u) => u.shifted(delta)).where((u) => u.end > 0).toList();
  }

  SubtitleStableUpdate add({required List<SubtitleCue> cues, required List<SubtitleWordTiming> words,
      required int windowEndMs, required bool flush}) {
    var units = words.isNotEmpty
        ? [for (final w in words) _SpeechUnit(w.startMs, w.endMs, w.text, w)]
        : [for (final c in cues) _SpeechUnit(c.startMs, c.endMs, c.text, null)];
    units = units.where((u) => u.text.trim().isNotEmpty && u.text.length <= 600 && u.end > u.start &&
      u.start >= 0 && u.end <= windowEndMs && u.end > committedThroughMs + 80 &&
      u.start >= committedThroughMs - 120).take(512).toList()..sort((a, b) => a.start.compareTo(b.start));
    final previous = _previous.where((u) => u.end > committedThroughMs + 80 &&
      u.start >= committedThroughMs - 120).toList();
    var shared = 0;
    while (shared < units.length && shared < previous.length) {
      final a = units[shared], b = previous[shared];
      if (a.normalized != b.normalized || (a.start - b.start).abs() > 800 ||
          (a.end - b.end).abs() > 800 || a.end > windowEndMs - 350) break;
      shared++;
    }
    final count = flush ? units.length : shared;
    final accepted = units.take(count).toList();
    final output = <SubtitleCue>[];
    final acceptedWords = <SubtitleWordTiming>[];
    var group = <_SpeechUnit>[];
    String join(List<_SpeechUnit> values) {
      final buffer = StringBuffer();
      for (final unit in values) {
        if (buffer.isNotEmpty && (unit.word == null || unit.word!.unit == SubtitleWordTimingUnit.word)) buffer.write(' ');
        buffer.write(unit.text.trim());
      }
      return buffer.toString();
    }
    void emit() {
      if (group.isEmpty) return;
      final start = math.max(0, group.first.start);
      final end = group.fold<int>(start + 1, (value, u) => math.max(value, u.end));
      output.add(SubtitleCue(index: 0, startMs: start, endMs: end, text: join(group)));
      for (final unit in group) { if (unit.word != null) acceptedWords.add(unit.word!); }
      committedThroughMs = end;
      group = [];
    }
    for (final unit in accepted) {
      if (group.isNotEmpty && (unit.start - group.last.end > 700 || unit.end - group.first.start > 2800 ||
          join(group).length + unit.text.length > 100 || RegExp(r'[.!?。！？]$').hasMatch(group.last.text))) emit();
      group.add(unit);
    }
    emit();
    _previous = units.skip(count).toList(growable: false);
    final remaining = _previous.take(32).toList();
    final preview = join(remaining);
    return SubtitleStableUpdate(List.unmodifiable(output), List.unmodifiable(acceptedWords),
      preview.isEmpty ? null : preview.substring(0, math.min(600, preview.length)), flush && count > shared);
  }
}
