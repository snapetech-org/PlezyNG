import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/subtitle_retimer.dart';
import 'package:plezy/services/subtitle_revision_service.dart';
import 'package:plezy/services/subtitle_sync_calibration.dart';
import 'package:plezy/services/subtitle_word_timing.dart';

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

  test('parsed cues have deterministic distinct identities that copies preserve', () {
    final bytes = utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nEcho\n\n2\n00:00:01,000 --> 00:00:02,000\nEcho\n');
    final first = SubtitleRetimer.parseCues(sourceBytes: bytes, extension: '.srt');
    final second = SubtitleRetimer.parseCues(sourceBytes: bytes, extension: '.srt');

    expect(first.map((cue) => cue.id), second.map((cue) => cue.id));
    expect(first.first.id, isNot(first.last.id));
    expect(first.first.copyWith(text: 'Edited', startMs: 1200).id, first.first.id);
  });

  test('word timing keeps its cue identity and refreshes its position after reordering', () {
    final cues = SubtitleRetimer.parseCues(
      sourceBytes: utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nFirst\n\n2\n00:00:03,000 --> 00:00:04,000\nSecond\n'),
      extension: '.srt',
    );
    final timing = SubtitleWordTiming(
      startMs: 1100,
      endMs: 1500,
      text: 'first',
      confidence: 0.9,
      unit: SubtitleWordTimingUnit.word,
      cueId: cues.first.id,
      cueIndex: 1,
    );
    final reordered = SubtitleWordTimingBuilder.attachCueReferences([timing], [cues.last, cues.first]).single;

    expect(reordered.cueId, cues.first.id);
    expect(reordered.cueIndex, 2);
  });

  test('revision v3 round-trips cue identities independently of cue order', () {
    final cues = SubtitleRetimer.parseCues(
      sourceBytes: utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nFirst\n\n2\n00:00:03,000 --> 00:00:04,000\nSecond\n'),
      extension: '.srt',
    );
    final revision = SubtitleRevision(
      id: '1000_abcd',
      createdAt: DateTime.utc(2026),
      operation: 'identity-test',
      languageCode: 'en',
      cues: [cues.last, cues.first],
      wordTimings: [
        SubtitleWordTiming(
          startMs: 1100,
          endMs: 1500,
          text: 'first',
          confidence: 0.9,
          unit: SubtitleWordTimingUnit.word,
          cueId: cues.first.id,
          cueIndex: 1,
        ),
      ],
    );

    final restored = SubtitleRevision.fromJson(revision.toJson());
    expect(restored.cues.map((cue) => cue.id), [cues.last.id, cues.first.id]);
    expect(restored.wordTimings.single.cueId, cues.first.id);
    expect(restored.wordTimings.single.cueIndex, 2);
  });

  test('legacy revision cue indexes migrate through the stored cue order field', () {
    final legacy = SubtitleRevision.fromJson({
      'schema': 'plezyng.subtitle-revision.v2',
      'id': '1000_abcd',
      'createdAt': '2026-01-01T00:00:00Z',
      'operation': 'legacy',
      'languageCode': 'en',
      'cues': [
        {'index': 2, 'startMs': 1000, 'endMs': 2000, 'text': 'Second'},
        {'index': 1, 'startMs': 3000, 'endMs': 4000, 'text': 'First'},
      ],
      'wordTimings': [
        {'startMs': 1200, 'endMs': 1400, 'text': 'word', 'confidence': 0.8, 'unit': 'word', 'cueIndex': 2},
      ],
    });

    expect(legacy.wordTimings.single.cueId, legacy.cues.first.id);
    expect(legacy.wordTimings.single.cueIndex, 1);
    expect(SubtitleRevision.fromJson(legacy.toJson()).wordTimings.single.cueId, legacy.cues.first.id);
  });

  test('revision rejects duplicate cue identities and dangling word references', () {
    final cues = SubtitleRetimer.parseCues(
      sourceBytes: utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nFirst\n\n2\n00:00:03,000 --> 00:00:04,000\nSecond\n'),
      extension: '.srt',
    );
    final valid = SubtitleRevision(
      id: '1000_abcd',
      createdAt: DateTime.utc(2026),
      operation: 'identity-test',
      languageCode: null,
      cues: cues,
      wordTimings: [
        SubtitleWordTiming(
          startMs: 1100,
          endMs: 1500,
          text: 'first',
          confidence: 0.9,
          unit: SubtitleWordTimingUnit.word,
          cueId: cues.first.id,
          cueIndex: 1,
        ),
      ],
    );
    final duplicate = valid.toJson();
    final duplicateCues = duplicate['cues'] as List<Map<String, Object?>>;
    duplicateCues[1] = {...duplicateCues[1], 'id': duplicateCues[0]['id']};
    expect(() => SubtitleRevision.fromJson(duplicate), throwsFormatException);

    final dangling = valid.toJson();
    final timings = dangling['wordTimings'] as List<Map<String, Object?>>;
    timings.single['cueId'] = '0' * 64;
    expect(() => SubtitleRevision.fromJson(dangling), throwsFormatException);
  });

  test('cue reference validation rejects duplicate or malformed cue IDs without timings', () {
    final malformed = SubtitleCue(id: 'not-a-sha256-id', index: 1, startMs: 1000, endMs: 2000, text: 'cue');
    final repeatedId = '0' * 64;
    final first = SubtitleCue(id: repeatedId, index: 1, startMs: 1000, endMs: 2000, text: 'first');
    final second = SubtitleCue(id: repeatedId, index: 2, startMs: 2000, endMs: 3000, text: 'second');

    expect(() => SubtitleWordTimingBuilder.attachCueReferences(const [], [malformed]), throwsFormatException);
    expect(() => SubtitleWordTimingBuilder.attachCueReferences(const [], [first, second]), throwsFormatException);
  });
}
