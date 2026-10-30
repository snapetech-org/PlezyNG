import 'subtitle_retimer.dart';
import 'subtitle_word_timing.dart';

/// A review aid for backend scores, never a probability of correct wording.
/// A Whisper word score may already average several tokens; other providers
/// return alignment scores with different meanings. Scores are not comparable
/// across those providers and do not establish timing or language accuracy.
final class SubtitleCueModelScore {
  const SubtitleCueModelScore(this.minimum, this.mean, this.spanCount);
  final double minimum;
  final double mean;
  final int spanCount;
}

final class SubtitleScoreReview {
  SubtitleScoreReview(List<SubtitleCue> cues, List<SubtitleWordTiming> words)
      : _originals = List<SubtitleCue>.unmodifiable(cues) {
    if (cues.length > SubtitleRetimer.maximumCueCount || words.length > 250000) {
      throw const FormatException('Model-score review exceeds the result limit.');
    }
    final byId = <String, int?>{};
    final byNumber = <int, int?>{};
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      byId[cue.stableId] = byId.containsKey(cue.stableId) ? null : i;
      byNumber[cue.index] = byNumber.containsKey(cue.index) ? null : i;
    }
    final totals = <int, double>{};
    final minima = <int, double>{};
    final counts = <int, int>{};
    for (final word in words) {
      if (!word.confidence.isFinite || word.confidence < 0 || word.confidence > 1 ||
          word.endMs <= word.startMs || word.text.trim().isEmpty) continue;
      // An explicitly unknown/ambiguous cue ID cannot fall back to another cue
      // with the same SRT number. Unlinked or ambiguous evidence stays unknown.
      final index = word.cueId != null ? byId[word.cueId] : byNumber[word.cueIndex];
      if (index == null) continue;
      final cue = cues[index];
      if (word.startMs >= cue.endMs || word.endMs <= cue.startMs ||
          (word.cueIndex != null && word.cueIndex != cue.index)) continue;
      totals[index] = (totals[index] ?? 0) + word.confidence;
      counts[index] = (counts[index] ?? 0) + 1;
      if (!minima.containsKey(index) || word.confidence < minima[index]!) {
        minima[index] = word.confidence;
      }
    }
    for (final entry in counts.entries) {
      _scores[entry.key] = SubtitleCueModelScore(
        minima[entry.key]!, totals[entry.key]! / entry.value, entry.value);
    }
  }

  final List<SubtitleCue> _originals;
  final Map<int, SubtitleCueModelScore> _scores = {};

  /// Text/time edits invalidate this evidence. Undo to the exact original can
  /// reveal it again; editing is not silently treated as a new model score.
  SubtitleCueModelScore? at(int index, SubtitleCue current) {
    if (index < 0 || index >= _originals.length) return null;
    final original = _originals[index];
    if (current.stableId != original.stableId || current.index != original.index ||
        current.startMs != original.startMs || current.endMs != original.endMs ||
        current.text != original.text) return null;
    return _scores[index];
  }

  bool flagged(int index, SubtitleCue cue, int thresholdPercent) {
    final score = at(index, cue);
    return thresholdPercent > 0 && thresholdPercent <= 100 && score != null &&
        score.minimum < thresholdPercent / 100;
  }

  int flaggedCount(List<SubtitleCue> cues, int thresholdPercent) {
    var count = 0;
    for (var i = 0; i < cues.length; i++) {
      if (flagged(i, cues[i], thresholdPercent)) count++;
    }
    return count;
  }
}
