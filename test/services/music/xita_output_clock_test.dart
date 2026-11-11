import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/xita_output_clock.dart';

void main() {
  for (final rate in [8000, 48000, 96000]) {
    for (final hardware in [.999, 1.001]) {
      test('audible clock follows $rate Hz at $hardware across ten minutes', () {
        final clock = XitaOutputClock(rate);
        const delay = 70000;
        for (var now = 100000; now <= 600000000; now += 50000) {
          final pts = Duration(microseconds: ((now - delay) * hardware).round());
          expect(clock.observe(pts, now), isTrue);
        }
        final waveFrame = (600000000 - delay) * hardware * rate / 1000000;
        final at = clock.presentationMicros(waveFrame.round());
        expect(at, closeTo(600000000, 1000));
        expect(clock.rateRatio, closeTo(hardware, .00004));
        expect(clock.frameAtMicros(at.round()), closeTo(waveFrame, 1));
      });
    }
  }
  test('invalid, stale, reversed and jumped observations do not poison output clock', () {
    final clock = XitaOutputClock(48000);
    expect(clock.observe(const Duration(microseconds: -1), 100000), isFalse);
    expect(clock.ready, isFalse);
    expect(clock.observe(const Duration(milliseconds: 50), 100000), isTrue);
    expect(clock.presentationMicros(2400), 100000);
    expect(clock.observe(const Duration(milliseconds: 50), 150000), isFalse);
    expect(clock.observe(const Duration(milliseconds: 40), 150000), isFalse);
    expect(clock.observe(const Duration(milliseconds: 60), 90000), isFalse);
    expect(clock.observe(const Duration(seconds: 10), 200000), isFalse);
    expect(clock.observe(const Duration(milliseconds: 100), 150000), isTrue);
    expect(clock.presentationMicros(4800), 150000);
    expect(clock.lastObservationMicros, 150000);
  });
}
