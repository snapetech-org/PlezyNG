import 'package:flutter_whisper_ggml/flutter_whisper.dart' as whisper;

import 'subtitle_retimer.dart';

enum SubtitleWordTimingUnit { word, syllable, token }

/// A source-timed lexical unit. Whisper-derived [confidence] is its mean token
/// probability, not a calibrated probability that the word is correct. A null
/// value means the source did not provide confidence metadata.
final class SubtitleWordTiming {
  const SubtitleWordTiming({
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.confidence,
    required this.unit,
    this.cueId,
    this.cueIndex,
  });

  final int startMs;
  final int endMs;
  final String text;
  final double? confidence;
  final SubtitleWordTimingUnit unit;

  /// Stable cue identity. This remains attached when the cue order changes.
  final String? cueId;

  /// One-based position kept for compatibility with older revision records.
  final int? cueIndex;

  SubtitleWordTiming withCueIndex(int? value) => SubtitleWordTiming(
    startMs: startMs,
    endMs: endMs,
    text: text,
    confidence: confidence,
    unit: unit,
    cueId: cueId,
    cueIndex: value,
  );

  SubtitleWordTiming withCueReference(String? id, int? index) => SubtitleWordTiming(
    startMs: startMs,
    endMs: endMs,
    text: text,
    confidence: confidence,
    unit: unit,
    cueId: id,
    cueIndex: index,
  );
}

/// Converts Whisper token timestamps into whitespace-delimited word timings
/// when the recognized segment has word separators. Segments without separators
/// retain honest token timings instead of inventing word boundaries.
abstract final class SubtitleWordTimingBuilder {
  static const int _maximumWordTimings = 250000;

  static List<SubtitleWordTiming> detachCueReferences(Iterable<SubtitleWordTiming> wordTimings) =>
      List<SubtitleWordTiming>.unmodifiable(wordTimings.map((timing) => timing.withCueReference(null, null)));

  static List<SubtitleWordTiming> fromWhisperSegments(
    Iterable<whisper.WhisperSegment> segments, {
    required int durationMs,
    int offsetMs = 0,
  }) {
    if (durationMs <= 0 || durationMs > SubtitleRetimer.maximumTimeMs) return const [];
    final output = <SubtitleWordTiming>[];
    for (final segment in segments) {
      final hasWordSeparators = RegExp(r'\s').hasMatch(segment.text.trim());
      StringBuffer? textBuffer;
      int? startMs;
      int? endMs;
      var probabilityTotal = 0.0;
      var probabilityCount = 0;

      void flush() {
        if (textBuffer == null || startMs == null || endMs == null || endMs! <= startMs!) {
          textBuffer = null;
          startMs = null;
          endMs = null;
          probabilityTotal = 0;
          probabilityCount = 0;
          return;
        }
        final text = textBuffer.toString().trim();
        if (text.isNotEmpty) {
          output.add(
            SubtitleWordTiming(
              startMs: startMs!,
              endMs: endMs!,
              text: text,
              confidence: probabilityCount == 0 ? 0 : (probabilityTotal / probabilityCount).clamp(0.0, 1.0).toDouble(),
              unit: hasWordSeparators ? SubtitleWordTimingUnit.word : SubtitleWordTimingUnit.token,
            ),
          );
        }
        textBuffer = null;
        startMs = null;
        endMs = null;
        probabilityTotal = 0;
        probabilityCount = 0;
      }

      for (final token in segment.tokens) {
        final raw = token.text;
        final tokenText = raw.trim();
        if (tokenText.isEmpty || RegExp(r'^<\|.*\|>$').hasMatch(tokenText)) {
          if (RegExp(r'\s').hasMatch(raw)) flush();
          continue;
        }
        final relativeStart = token.start.inMilliseconds;
        final relativeEnd = token.end.inMilliseconds;
        if (relativeStart < 0 || relativeEnd <= relativeStart) continue;
        final start = (offsetMs + relativeStart).clamp(0, durationMs).toInt();
        final end = (offsetMs + relativeEnd).clamp(0, durationMs).toInt();
        if (end <= start) continue;

        final beginsWithWhitespace = RegExp(r'^\s').hasMatch(raw);
        final punctuationOnly = RegExp(r'^[\p{P}\p{S}]+$', unicode: true).hasMatch(tokenText);
        if (beginsWithWhitespace && !punctuationOnly) flush();

        // A native token that contains multiple whitespace-separated words
        // has no internal per-word timestamps, so retain it as a token span.
        if (RegExp(r'\s').hasMatch(tokenText)) {
          flush();
          output.add(
            SubtitleWordTiming(
              startMs: start,
              endMs: end,
              text: tokenText,
              confidence: token.probability.isFinite ? token.probability.clamp(0.0, 1.0).toDouble() : 0.0,
              unit: SubtitleWordTimingUnit.token,
            ),
          );
          continue;
        }

        textBuffer ??= StringBuffer();
        startMs ??= start;
        endMs = endMs == null || end > endMs! ? end : endMs;
        textBuffer!.write(tokenText);
        final probability = token.probability;
        if (probability.isFinite) {
          probabilityTotal += probability.clamp(0.0, 1.0).toDouble();
          probabilityCount++;
        }
        if (output.length >= _maximumWordTimings) return List.unmodifiable(output);
      }
      flush();
      if (output.length >= _maximumWordTimings) break;
    }
    output.sort((a, b) {
      final time = a.startMs.compareTo(b.startMs);
      return time != 0 ? time : a.endMs.compareTo(b.endMs);
    });
    return List.unmodifiable(output);
  }

  static List<SubtitleWordTiming> attachCueReferences(List<SubtitleWordTiming> wordTimings, List<SubtitleCue> cues) {
    final cuePositions = <String, int>{};
    for (var index = 0; index < cues.length; index++) {
      if (!SubtitleCue.isValidId(cues[index].id)) {
        throw const FormatException('Subtitle cue identity is invalid.');
      }
      if (cuePositions.containsKey(cues[index].id)) {
        throw const FormatException('Subtitle cue identities must be unique.');
      }
      cuePositions[cues[index].id] = index;
    }
    if (wordTimings.isEmpty) return const <SubtitleWordTiming>[];
    final orderedCues = List<int>.generate(cues.length, (index) => index)
      ..sort((left, right) {
        final start = cues[left].startMs.compareTo(cues[right].startMs);
        if (start != 0) return start;
        final end = cues[left].endMs.compareTo(cues[right].endMs);
        return end != 0 ? end : left.compareTo(right);
      });
    final wordOrder = List<int>.generate(wordTimings.length, (index) => index)
      ..sort((left, right) {
        final start = wordTimings[left].startMs.compareTo(wordTimings[right].startMs);
        if (start != 0) return start;
        final end = wordTimings[left].endMs.compareTo(wordTimings[right].endMs);
        return end != 0 ? end : left.compareTo(right);
      });
    final result = List<SubtitleWordTiming>.of(wordTimings);
    var firstPossibleCue = 0;
    for (final wordPosition in wordOrder) {
      final word = wordTimings[wordPosition];
      if (word.cueId case final cueId?) {
        final cuePosition = cuePositions[cueId];
        if (cuePosition == null) {
          throw const FormatException('Word timing references a missing subtitle cue identity.');
        }
        result[wordPosition] = word.withCueReference(cueId, cuePosition + 1);
        continue;
      }
      while (firstPossibleCue < orderedCues.length && cues[orderedCues[firstPossibleCue]].endMs < word.startMs) {
        firstPossibleCue++;
      }
      var bestPosition = -1;
      var bestOverlap = 0;
      for (
        var cursor = firstPossibleCue;
        cursor < orderedCues.length && cues[orderedCues[cursor]].startMs <= word.endMs;
        cursor++
      ) {
        final cuePosition = orderedCues[cursor];
        final cue = cues[cuePosition];
        final overlap =
            (cue.endMs < word.endMs ? cue.endMs : word.endMs) -
            (cue.startMs > word.startMs ? cue.startMs : word.startMs);
        if (overlap > bestOverlap) {
          bestOverlap = overlap;
          bestPosition = cuePosition;
        }
      }
      final legacyIndex = word.cueIndex;
      if (bestPosition < 0 && legacyIndex != null && legacyIndex >= 1 && legacyIndex <= cues.length) {
        bestPosition = legacyIndex - 1;
      }
      result[wordPosition] = bestPosition < 0
          ? word.withCueReference(null, null)
          : word.withCueReference(cues[bestPosition].id, bestPosition + 1);
    }
    return List<SubtitleWordTiming>.unmodifiable(result);
  }

  /// Compatibility name for callers that still consume a positional cue field.
  static List<SubtitleWordTiming> attachCueIndices(List<SubtitleWordTiming> wordTimings, List<SubtitleCue> cues) =>
      attachCueReferences(wordTimings, cues);
}
