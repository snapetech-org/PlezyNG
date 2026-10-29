import 'dart:math' as math;

/// A source-clock observation supplied by the viewer, never an inferred match.
final class SubtitleSyncAnchor {
  const SubtitleSyncAnchor(this.subtitleSeconds, this.playbackSeconds);
  final double subtitleSeconds;
  final double playbackSeconds;
  bool get valid => [subtitleSeconds, playbackSeconds].every((value) =>
    value.isFinite && value >= 0 && value <= 60 * 24 * 60 * 60);
}

final class SubtitleSyncFit {
  const SubtitleSyncFit(this.calibration, this.anchors, this.residualSeconds);
  final SubtitleSyncCalibration calibration;
  final List<SubtitleSyncAnchor> anchors;
  final List<double> residualSeconds;
  double get maximumResidualSeconds => residualSeconds.fold(0.0, (a, b) => math.max(a, b.abs()));
  double get rmsSeconds => math.sqrt(residualSeconds.fold(0.0, (a, b) => a + b * b) / residualSeconds.length);
  // A fit never silently drops observations. Larger residuals require changing
  // the anchors or using the existing piecewise/cut-aware synchronization path.
  bool get consistent => maximumResidualSeconds <= .75;
}

/// A bounded affine fit for subtitle tracks whose timing drifts over the runtime.
///
/// mpv applies subtitle timestamps as `sourceTime * timestampMultiplier + delay`.
/// Given two subtitle cue times and the playback times those cues should match,
/// this solves the linear correction without modifying the subtitle file.
final class SubtitleSyncCalibration {
  const SubtitleSyncCalibration({required this.timestampMultiplier, required this.delayMs});

  static const minimumAnchorSpanSeconds = 60.0;
  static const minimumTimestampMultiplier = 0.8;
  static const maximumTimestampMultiplier = 1.25;
  static const minimumDelayMs = -60000;
  static const maximumDelayMs = 60000;

  final double timestampMultiplier;
  final int delayMs;

  static SubtitleSyncFit fitAnchors(List<SubtitleSyncAnchor> observations) {
    if (observations.length < 2 || observations.length > 12 || observations.any((point) => !point.valid)) {
      throw ArgumentError('Choose between two and twelve finite source-clock anchors.');
    }
    final anchors = List<SubtitleSyncAnchor>.of(observations)
      ..sort((a, b) => a.subtitleSeconds.compareTo(b.subtitleSeconds));
    for (var i = 1; i < anchors.length; i++) {
      if (anchors[i].subtitleSeconds <= anchors[i - 1].subtitleSeconds ||
          anchors[i].playbackSeconds <= anchors[i - 1].playbackSeconds) {
        throw ArgumentError('Anchor order must increase on both clocks.');
      }
    }
    if (anchors.last.playbackSeconds - anchors.first.playbackSeconds < minimumAnchorSpanSeconds) {
      throw ArgumentError('Choose anchors at least sixty seconds apart.');
    }
    final slopes = <double>[];
    for (var i = 0; i < anchors.length; i++) {
      for (var j = i + 1; j < anchors.length; j++) {
        final span = anchors[j].subtitleSeconds - anchors[i].subtitleSeconds;
        if (span >= minimumAnchorSpanSeconds) {
          slopes.add((anchors[j].playbackSeconds - anchors[i].playbackSeconds) / span);
        }
      }
    }
    if (slopes.isEmpty) throw ArgumentError('Choose anchors at least sixty seconds apart.');
    double median(List<double> values) {
      values.sort();
      final middle = values.length ~/ 2;
      return values.length.isOdd ? values[middle] : (values[middle - 1] + values[middle]) / 2;
    }
    final rate = median(slopes);
    final offset = median([for (final anchor in anchors) anchor.playbackSeconds - rate * anchor.subtitleSeconds]);
    final delayMs = (offset * 1000).round();
    if (!rate.isFinite || rate < minimumTimestampMultiplier || rate > maximumTimestampMultiplier ||
        delayMs < minimumDelayMs || delayMs > maximumDelayMs) {
      throw ArgumentError('Anchor fit exceeds the supported rate or delay.');
    }
    final calibration = SubtitleSyncCalibration(timestampMultiplier: rate, delayMs: delayMs);
    return SubtitleSyncFit(calibration, List.unmodifiable(observations), List.unmodifiable([
      for (final point in observations) point.playbackSeconds - (point.subtitleSeconds * rate + delayMs / 1000),
    ]));
  }

  factory SubtitleSyncCalibration.fromAnchors({
    required double subtitleTime1Seconds,
    required double playbackTime1Seconds,
    required double subtitleTime2Seconds,
    required double playbackTime2Seconds,
  }) {
    final values = [subtitleTime1Seconds, playbackTime1Seconds, subtitleTime2Seconds, playbackTime2Seconds];
    if (values.any((value) => !value.isFinite || value < 0)) {
      throw ArgumentError('Anchor times must be finite, non-negative values.');
    }

    final subtitleSpan = subtitleTime2Seconds - subtitleTime1Seconds;
    final playbackSpan = playbackTime2Seconds - playbackTime1Seconds;
    if (subtitleSpan < minimumAnchorSpanSeconds || playbackSpan < minimumAnchorSpanSeconds) {
      throw ArgumentError('Choose increasing anchors at least 60 seconds apart.');
    }

    final multiplier = playbackSpan / subtitleSpan;
    if (!multiplier.isFinite || multiplier < minimumTimestampMultiplier || multiplier > maximumTimestampMultiplier) {
      throw RangeError.value(
        multiplier,
        'timestampMultiplier',
        'Must be finite and between $minimumTimestampMultiplier and $maximumTimestampMultiplier',
      );
    }

    final delayMs = ((playbackTime1Seconds - multiplier * subtitleTime1Seconds) * 1000).round();
    if (delayMs < minimumDelayMs || delayMs > maximumDelayMs) {
      throw RangeError.range(delayMs, minimumDelayMs, maximumDelayMs, 'delayMs');
    }

    return SubtitleSyncCalibration(timestampMultiplier: multiplier, delayMs: delayMs);
  }
}
