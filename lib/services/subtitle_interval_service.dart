import 'subtitle_retimer.dart';

/// A half-open time range on the media timeline, in milliseconds.
final class SubtitleAudioInterval {
  const SubtitleAudioInterval({required this.startMs, required this.endMs});

  final int startMs;
  final int endMs;

  bool isWithin(int durationMs) => startMs >= 0 && endMs > startMs && endMs <= durationMs;

  static SubtitleAudioInterval? parse(String start, String end, {required int durationMs}) {
    final startMs = parseTimecode(start);
    final endMs = parseTimecode(end);
    if (startMs == null || endMs == null) return null;
    final interval = SubtitleAudioInterval(startMs: startMs, endMs: endMs);
    return interval.isWithin(durationMs) ? interval : null;
  }

  static int? parseTimecode(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    final components = value.split(':');
    if (components.length < 2 || components.length > 3) return null;
    final secondsAndFraction = components.removeLast().split('.');
    if (secondsAndFraction.length > 2) return null;
    final seconds = int.tryParse(secondsAndFraction.first);
    final hasHours = components.length == 2;
    final minutes = int.tryParse(components.removeLast());
    final hours = components.isEmpty ? 0 : int.tryParse(components.single);
    if (seconds == null ||
        minutes == null ||
        hours == null ||
        seconds < 0 ||
        minutes < 0 ||
        hours < 0 ||
        seconds > 59 ||
        (hasHours && minutes > 59)) {
      return null;
    }
    var milliseconds = 0;
    if (secondsAndFraction.length == 2) {
      final fraction = secondsAndFraction.last;
      final fractionValue = int.tryParse(fraction);
      if (fraction.isEmpty || fraction.length > 3 || fractionValue == null || fractionValue < 0) return null;
      milliseconds = int.parse(fraction.padRight(3, '0'));
    }
    return ((hours * 60 + minutes) * 60 + seconds) * 1000 + milliseconds;
  }

  static String formatTimecode(int valueMs) {
    final totalSeconds = valueMs.clamp(0, 359999999).toInt() ~/ 1000;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${pad(hours)}:${pad(minutes)}:${pad(seconds)}';
  }
}

/// Builds independent, reviewable subtitle documents from selected WAV ranges.
abstract final class SubtitleIntervalService {
  static const int _minimumGapMs = 1500;
  static const int _gapBoundaryToleranceMs = 250;

  /// Replaces only cues intersecting [interval], clipping boundary cues. The
  /// input cues outside the selected range retain their stable identities.
  static List<SubtitleCue> replaceRange({
    required List<SubtitleCue> existing,
    required List<SubtitleCue> generated,
    required SubtitleAudioInterval interval,
  }) {
    final merged = <SubtitleCue>[];
    for (final cue in existing) {
      if (cue.endMs <= interval.startMs || cue.startMs >= interval.endMs) {
        merged.add(_preserveIdentity(cue));
        continue;
      }
      final hasBefore = cue.startMs < interval.startMs;
      final hasAfter = cue.endMs > interval.endMs;
      if (hasBefore) {
        merged.add(
          SubtitleCue(
            index: cue.index,
            startMs: cue.startMs,
            endMs: interval.startMs,
            text: cue.text,
            cueId: cue.stableId,
          ),
        );
      }
      if (hasAfter) {
        merged.add(
          SubtitleCue(
            index: cue.index,
            startMs: interval.endMs,
            endMs: cue.endMs,
            text: cue.text,
            cueId: hasBefore ? null : cue.stableId,
          ),
        );
      }
    }

    for (final cue in generated) {
      final startMs = cue.startMs.clamp(interval.startMs, interval.endMs).toInt();
      final endMs = cue.endMs.clamp(interval.startMs, interval.endMs).toInt();
      if (endMs <= startMs || cue.text.trim().isEmpty) continue;
      merged.add(
        SubtitleCue(
          index: cue.index,
          startMs: startMs,
          endMs: endMs,
          text: cue.text,
          cueId: cue.cueId,
        ),
      );
    }
    return _renumber(merged, rejectEmpty: true, emptyMessage: 'Interval generation produced no valid cues.');
  }

  /// Adds ASR cues only when their midpoint is in a long uncovered range.
  /// Existing cue timing/text is never changed by this gap-fill mode.
  static List<SubtitleCue> fillSpeechDetectedGaps({
    required List<SubtitleCue> existing,
    required List<SubtitleCue> generated,
    required SubtitleAudioInterval interval,
  }) {
    final orderedExisting = existing.toList()..sort(_compareCues);
    final gaps = <(int, int)>[];
    var cursorMs = interval.startMs;
    for (final cue in orderedExisting) {
      if (cue.endMs <= interval.startMs || cue.startMs >= interval.endMs) continue;
      final cueStartMs = cue.startMs.clamp(interval.startMs, interval.endMs).toInt();
      final cueEndMs = cue.endMs.clamp(interval.startMs, interval.endMs).toInt();
      if (cueStartMs - cursorMs >= _minimumGapMs) gaps.add((cursorMs, cueStartMs));
      if (cueEndMs > cursorMs) cursorMs = cueEndMs;
    }
    if (interval.endMs - cursorMs >= _minimumGapMs) gaps.add((cursorMs, interval.endMs));

    final additions = <SubtitleCue>[];
    for (final speech in generated) {
      final midpointMs = speech.startMs + ((speech.endMs - speech.startMs) ~/ 2);
      (int, int)? selectedGap;
      for (final gap in gaps) {
        final toleratedStartMs = gap.$1 - _gapBoundaryToleranceMs;
        final toleratedEndMs = gap.$2 + _gapBoundaryToleranceMs;
        if (midpointMs >= gap.$1 &&
            midpointMs <= gap.$2 &&
            speech.startMs >= toleratedStartMs &&
            speech.endMs <= toleratedEndMs) {
          selectedGap = gap;
          break;
        }
      }
      if (selectedGap == null) continue;
      final startMs = speech.startMs.clamp(selectedGap.$1, selectedGap.$2).toInt();
      final endMs = speech.endMs.clamp(selectedGap.$1, selectedGap.$2).toInt();
      if (endMs <= startMs || speech.text.trim().isEmpty) continue;
      if (orderedExisting.any((cue) => cue.startMs < endMs && cue.endMs > startMs)) continue;
      final normalizedText = speech.text.trim().toLowerCase();
      final duplicate = [...orderedExisting, ...additions].any(
        (cue) => cue.text.trim().toLowerCase() == normalizedText && (cue.startMs - startMs).abs() < 2000,
      );
      if (duplicate) continue;
      additions.add(SubtitleCue(index: 0, startMs: startMs, endMs: endMs, text: speech.text));
    }

    if (additions.isEmpty) {
      throw const FormatException('No speech-detected subtitle gaps were found in the selected interval.');
    }
    return _renumber(
      [...orderedExisting, ...additions],
      rejectEmpty: false,
      emptyMessage: 'Gap filling produced no cues.',
      preserve: existing,
    );
  }

  static SubtitleCue _preserveIdentity(SubtitleCue cue) => SubtitleCue(
    index: cue.index,
    startMs: cue.startMs,
    endMs: cue.endMs,
    text: cue.text,
    cueId: cue.stableId,
  );

  static int _compareCues(SubtitleCue left, SubtitleCue right) {
    final start = left.startMs.compareTo(right.startMs);
    return start == 0 ? left.endMs.compareTo(right.endMs) : start;
  }

  static List<SubtitleCue> _renumber(
    List<SubtitleCue> cues, {
    required bool rejectEmpty,
    required String emptyMessage,
    List<SubtitleCue> preserve = const <SubtitleCue>[],
  }) {
    cues.sort(_compareCues);
    if ((rejectEmpty && cues.isEmpty) || cues.length > SubtitleRetimer.maximumCueCount) {
      throw FormatException(emptyMessage);
    }
    return List<SubtitleCue>.unmodifiable([
      for (var index = 0; index < cues.length; index++)
        SubtitleCue(
          index: index + 1,
          startMs: cues[index].startMs,
          endMs: cues[index].endMs,
          text: cues[index].text,
          cueId: cues[index].cueId == null && preserve.contains(cues[index])
              ? cues[index].stableId
              : cues[index].cueId,
        ),
    ]);
  }
}
