import 'dart:math' as math;

import 'subtitle_retimer.dart';

/// Conservative sentence-fragment grouping and reviewed duration-weighted text
/// layout. It does not align translated words to speech or infer speaker identity.
final class SubtitleSentenceGroup {
  SubtitleSentenceGroup(List<SubtitleCue> cues, List<int> cueIndices)
      : cues = List.unmodifiable(cues), cueIndices = List.unmodifiable(cueIndices) {
    if (cues.isEmpty || cues.length != cueIndices.length) throw ArgumentError('Sentence group cues and indexes must match.');
  }
  final List<SubtitleCue> cues;
  final List<int> cueIndices;
  SubtitleCue get input => SubtitleCue(index: cues.first.index, startMs: cues.first.startMs,
    endMs: cues.last.endMs, text: cues.length == 1 ? cues.first.text
        : cues.map((cue) => cue.text.trim().replaceAll(RegExp(r'\s+'), ' ')).join(' '),
    cueId: cues.first.stableId);
}

final class SubtitleSentenceLayout {
  static final _sentenceEnd = RegExp(r'''[.!?。！？…]["'”’»）)\]]*$''');
  static final _authored = RegExp(r'[<>{}\\\[\]♪♫]|^\s*[-–—]|\n\s*[-–—]|^[^\n:：]{1,40}[:：]\s', multiLine: true);

  static List<SubtitleSentenceGroup> group(List<SubtitleCue> cues) {
    final output = <SubtitleSentenceGroup>[];
    var active = <SubtitleCue>[];
    var activeIndices = <int>[];
    var characters = 0;
    for (var cueIndex = 0; cueIndex < cues.length; cueIndex++) {
      final cue = cues[cueIndex];
      if (cue.endMs <= cue.startMs || cue.startMs < 0) throw const FormatException('Invalid sentence cue clock.');
      final text = cue.text.trim();
      final previous = active.isEmpty ? null : active.last;
      final canJoin = text.isNotEmpty && previous != null && previous.text.trim().isNotEmpty && active.length < 6 &&
          !_authored.hasMatch(text) && !_authored.hasMatch(previous.text) &&
          !_sentenceEnd.hasMatch(previous.text.trim()) &&
          cue.startMs >= previous.endMs && cue.startMs - previous.endMs <= 350 &&
          cue.endMs - active.first.startMs <= 12000 && characters + text.length + 1 <= 2400;
      if (!canJoin && active.isNotEmpty) {
        output.add(SubtitleSentenceGroup(active, activeIndices));
        active = [];
        activeIndices = [];
        characters = 0;
      }
      active.add(cue);
      activeIndices.add(cueIndex);
      characters += text.length + 1;
      if (_sentenceEnd.hasMatch(text) || _authored.hasMatch(text)) {
        output.add(SubtitleSentenceGroup(active, activeIndices));
        active = [];
        activeIndices = [];
        characters = 0;
      }
    }
    if (active.isNotEmpty) output.add(SubtitleSentenceGroup(active, activeIndices));
    return List.unmodifiable(output);
  }

  /// Return null when every original cue cannot receive a nonempty, bounded
  /// fragment. The caller then translates those source cues independently.
  static List<String>? distribute(SubtitleSentenceGroup group, String translated,
      {required Iterable<String> protectedTerms, required int charactersPerSecond}) {
    if (group.cues.length == 1) return [translated];
    if (charactersPerSecond < 5 || charactersPerSecond > 60 || translated.length > 4000 ||
        _authored.hasMatch(translated)) return null;
    final text = translated.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty) return null;
    final protectedRanges = <(int, int)>[];
    bool addProtectedRange(int start, int end) {
      if (protectedRanges.length >= 8192) return false;
      protectedRanges.add((start, end));
      return true;
    }
    final terms = protectedTerms.map((term) => term.trim().replaceAll(RegExp(r'\s+'), ' '))
        .where((term) => term.isNotEmpty).toSet();
    for (final normalized in terms) {
      for (final match in RegExp(RegExp.escape(normalized), caseSensitive: false, unicode: true).allMatches(text)) {
        if (!addProtectedRange(match.start, match.end)) return null;
      }
    }
    // Keep numeric expressions together, including decimals and grouped digits.
    for (final match in RegExp(r'\d+(?:[ ,.:/\-]\d+)*').allMatches(text)) {
      if (!addProtectedRange(match.start, match.end)) return null;
    }
    protectedRanges.sort((a, b) {
      final start = a.$1.compareTo(b.$1);
      return start == 0 ? a.$2.compareTo(b.$2) : start;
    });
    final mergedRanges = <(int, int)>[];
    for (final range in protectedRanges) {
      if (mergedRanges.isEmpty || range.$1 > mergedRanges.last.$2) {
        mergedRanges.add(range);
      } else {
        final previous = mergedRanges.removeLast();
        mergedRanges.add((previous.$1, range.$2 > previous.$2 ? range.$2 : previous.$2));
      }
    }
    bool protected(int boundary) {
      var low = 0, high = mergedRanges.length;
      while (low < high) {
        final middle = low + (high - low) ~/ 2;
        if (mergedRanges[middle].$1 < boundary) low = middle + 1;
        else high = middle;
      }
      return low > 0 && boundary < mergedRanges[low - 1].$2;
    }
    final boundaries = <int>[0];
    for (var offset = 0; offset < text.length; offset++) {
      final code = text.codeUnitAt(offset);
      final space = code == 32;
      final punctuation = const {0x3001, 0xff0c, 0x3002, 0xff01, 0xff1f, 0xff1b, 0xff1a}.contains(code);
      final boundary = space ? offset : offset + 1;
      if ((!space && !punctuation) || boundary == 0 || boundary == text.length || protected(boundary)) continue;
      if (RegExp(r'^\p{M}', unicode: true).hasMatch(text.substring(boundary))) continue;
      if (boundaries.last != boundary) boundaries.add(boundary);
    }
    boundaries.add(text.length);
    if (boundaries.length - 1 < group.cues.length || boundaries.length > 2000) return null;
    final duration = group.cues.fold<int>(0, (sum, cue) => sum + cue.endMs - cue.startMs);
    final output = <String>[];
    var startIndex = 0, elapsed = 0;
    for (var cueIndex = 0; cueIndex < group.cues.length; cueIndex++) {
      final cue = group.cues[cueIndex];
      elapsed += cue.endMs - cue.startMs;
      final remaining = group.cues.length - cueIndex - 1;
      var endIndex = boundaries.length - 1;
      if (remaining > 0) {
        final target = text.length * elapsed / duration;
        var best = double.infinity;
        for (var candidate = startIndex + 1; candidate < boundaries.length - remaining; candidate++) {
          final part = text.substring(boundaries[startIndex], boundaries[candidate]).trim();
          if (part.isEmpty) continue;
          final penalty = RegExp(r'[,;:!?。.，、；：！？]$').hasMatch(part) ? 0 : 4;
          final cost = (boundaries[candidate] - target).abs() + penalty;
          if (cost < best) { best = cost; endIndex = candidate; }
        }
      }
      if (endIndex <= startIndex) return null;
      final part = text.substring(boundaries[startIndex], boundaries[endIndex]).trim();
      if (part.isEmpty || part.length > 4000 ||
          part.runes.length * 1000 / math.max(1, cue.endMs - cue.startMs) > charactersPerSecond) return null;
      output.add(part);
      startIndex = endIndex;
    }
    return startIndex == boundaries.length - 1 ? List.unmodifiable(output) : null;
  }
}
