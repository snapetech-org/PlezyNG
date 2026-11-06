import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/subtitle_capture_timeline.dart';

void main() {
  test('live PTS rollover discards the previous caption epoch', () {
    final clock = SubtitleCaptureTimeline(live: true, seekGeneration: 0);
    expect(clock.accept(ptsUs: 90000000, durationUs: 20000, seekGeneration: 0), SubtitleCapturePacketAction.append);
    expect(clock.accept(ptsUs: 1000, durationUs: 20000, seekGeneration: 0), SubtitleCapturePacketAction.resetTimeline);
    expect(clock.accept(ptsUs: 21000, durationUs: 20000, seekGeneration: 0), SubtitleCapturePacketAction.append);
  });
  test('DVR seek retains cues but rejects queued audio from the old position', () {
    final clock = SubtitleCaptureTimeline(live: true, seekGeneration: 0);
    clock.accept(ptsUs: 90000000, durationUs: 20000, seekGeneration: 0);
    expect(
      clock.accept(ptsUs: 90020000, durationUs: 20000, seekGeneration: 1, seekTargetUs: 10000000),
      SubtitleCapturePacketAction.discard,
    );
    expect(
      clock.accept(ptsUs: 10000000, durationUs: 20000, seekGeneration: 1, seekTargetUs: 10000000),
      SubtitleCapturePacketAction.resetWindow,
    );
    expect(clock.accept(ptsUs: 10020000, durationUs: 20000, seekGeneration: 1), SubtitleCapturePacketAction.append);
  });
  test('pause and format changes cannot invent a new live caption epoch', () {
    final clock = SubtitleCaptureTimeline(live: true, seekGeneration: 0);
    clock.accept(ptsUs: 1000000, durationUs: 20000, seekGeneration: 0);
    expect(clock.accept(ptsUs: 1020000, durationUs: 20000, seekGeneration: 0), SubtitleCapturePacketAction.append);
    expect(
      clock.accept(ptsUs: 1040000, durationUs: 20000, seekGeneration: 0, formatChanged: true),
      SubtitleCapturePacketAction.resetWindow,
    );
  });
  test('VOD discontinuities retain other watched portions', () {
    final clock = SubtitleCaptureTimeline(live: false, seekGeneration: 0);
    clock.accept(ptsUs: 90000000, durationUs: 20000, seekGeneration: 0);
    expect(clock.accept(ptsUs: 1000000, durationUs: 20000, seekGeneration: 0), SubtitleCapturePacketAction.resetWindow);
  });
}
