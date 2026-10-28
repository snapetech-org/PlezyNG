import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/subtitle_retimer.dart';
import 'package:plezy/services/subtitle_sync_calibration.dart';

void main() {
  test('fractional drift calibration maps both anchors', () {
    final fit = SubtitleSyncCalibration.fromAnchors(
      subtitleTime1Seconds: 60,
      playbackTime1Seconds: 61,
      subtitleTime2Seconds: 180,
      playbackTime2Seconds: 181.6,
    );
    expect(fit.timestampMultiplier, closeTo(1.005, 0.000001));
    expect(fit.delayMs, 700);
  });

  test('out-of-bounds fractional drift is rejected', () {
    expect(
      () => SubtitleSyncCalibration.fromAnchors(
        subtitleTime1Seconds: 0,
        playbackTime1Seconds: 0,
        subtitleTime2Seconds: 100,
        playbackTime2Seconds: 130,
      ),
      throwsRangeError,
    );
  });

  for (final rate in [0.79, 1.26, double.nan, double.infinity]) {
    test('retiming rejects invalid rate $rate', () {
      expect(
        () => SubtitleRetimer.retime(
          sourceBytes: utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nHello\n'),
          extension: '.srt',
          delayMs: 0,
          rate: rate,
        ),
        throwsRangeError,
      );
    });
  }

  test('fractional retiming preserves cue text and the input bytes', () {
    const source = '1\r\n00:00:01,000 --> 00:00:02,000\r\nHello\r\n';
    final bytes = utf8.encode(source);
    final result = SubtitleRetimer.retime(sourceBytes: bytes, extension: '.srt', delayMs: 500, rate: 1.1);
    expect(utf8.decode(result.bytes), '1\r\n00:00:01,600 --> 00:00:02,700\r\nHello\r\n');
    expect(utf8.decode(bytes), source);
  });
}
