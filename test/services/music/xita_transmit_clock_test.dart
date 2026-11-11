import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/xita_transmit_clock.dart';

void main() {
  test('source rate feedback bounds ten minutes of hardware drift in both directions', () {
    for (final ppm in [-1000, -200, 200, 1000]) {
      final clock = XitaTransmitClock(startMicros: 0, timestamp: DateTime.utc(2026));
      var frames = 0, minimum = 4800, maximum = 4800;
      while (clock.nextMicros < 600000000) {
        final now = clock.nextMicros;
        final produced = 4800 + (now * 48000 / 1000000 * (1 + ppm / 1000000)).round();
        final buffered = produced - frames;
        if (buffered < minimum) minimum = buffered;
        if (buffered > maximum) maximum = buffered;
        clock.advance(now, bufferedFrames: buffered);
        frames += 1024;
        expect(clock.rateRatio, inInclusiveRange(.998, 1.002));
      }
      expect(minimum, greaterThan(1800), reason: '$ppm ppm');
      expect(maximum, lessThan(8000), reason: '$ppm ppm');
      expect((clock.rateRatio - (1 + ppm / 1000000)).abs(), lessThan(.00005));
    }
  });
  test('monotonic descriptors survive wall-clock era boundaries and stalled senders fail closed', () {
    final wall = DateTime.utc(2036, 2, 7, 6, 28, 15);
    final clock = XitaTransmitClock(startMicros: 100000, timestamp: wall);
    expect(clock.timestampAt(1100000), wall.add(const Duration(seconds: 1)));
    expect(clock.due(99999), isFalse);
    expect(clock.due(100000), isTrue);
    expect(clock.lateness(101500), 1500);
    expect(() => clock.advance(400001, bufferedFrames: 4800), throwsStateError);
  });
}
