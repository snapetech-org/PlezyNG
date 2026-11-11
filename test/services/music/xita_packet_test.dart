import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/xita_packet.dart';

Uint8List hex(String text) =>
    Uint8List.fromList([for (var i = 0; i < text.length; i += 2) int.parse(text.substring(i, i + 2), radix: 16)]);
XitaAudio audio(int frame, {int flags = 1, int delay = 0}) =>
    XitaPacket.decode(
          XitaAudio.encode(
            frame: frame,
            channels: 2,
            samples: Float32List(20),
            flags: flags,
            transmitDelayMicros: delay,
          ),
        )!
        as XitaAudio;

void main() {
  test('captured native descriptor has 32-byte header, NTP and network byte order', () {
    final packet =
        XitaPacket.decode(hex('7a6e6a6200000202000005c00000ac440000040000c6c400edd66a0f2f603925'))! as XitaDescriptor;
    expect(packet.sampleRate, 44100);
    expect(packet.periodFrames, 1024);
    expect(packet.mtu, 1472);
    expect(packet.frame, 0xc6c400);
    expect(packet.timestampNear(DateTime.utc(2026)).year, 2026);
  });
  test('first PCM sample starts at byte 20; dtime is microseconds', () {
    final packet = XitaPacket.decode(hex('7a6e6a62010102020000010000000001000000943f000000bf800000'))! as XitaAudio;
    expect(packet.transmitDelayMicros, 148);
    expect(packet.frame, 256);
    expect(packet.samples, [.5, -1]);
  });
  test('float32 and signed integer formats decode without host endian assumptions', () {
    for (final entry in {
      '7a6e6a62010000020000000100000001000000007fff8001': [1.0, -1.0],
      '7a6e6a62010001020000000100000001000000007fffff800001': [1.0, -1.0],
    }.entries) {
      expect((XitaPacket.decode(hex(entry.key))! as XitaAudio).samples, entry.value);
    }
  });
  test('encoder is bounded, exact and rejects non-finite samples', () {
    final encoded = XitaAudio.encode(frame: 0xffffffff, channels: 2, samples: Float32List.fromList([.25, -.5]));
    final decoded = XitaPacket.decode(encoded)! as XitaAudio;
    expect(decoded.samples, [.25, -.5]);
    expect(decoded.frame, 0xffffffff);
    for (var length = 0; length < encoded.length; length++) {
      expect(XitaPacket.decode(Uint8List.sublistView(encoded, 0, length)), isNull);
    }
    expect(XitaPacket.decode(Uint8List(65507)), isNull);
    expect(
      () => XitaAudio.encode(frame: 0, channels: 2, samples: Float32List.fromList([double.nan, 0])),
      throwsArgumentError,
    );
    expect(() => XitaAudio.encode(frame: 0, channels: 2, samples: Float32List(4096)), throwsArgumentError);
    final poisoned = Uint8List.fromList(encoded);
    ByteData.sublistView(poisoned).setFloat32(20, double.infinity);
    expect(XitaPacket.decode(poisoned), isNull);
  });
  test('skip and terminate tokens carry no invented PCM', () {
    for (final flags in [4, 128]) {
      final token =
          XitaPacket.decode(
                XitaAudio.encode(frame: 10, channels: 2, samples: Float32List(0), flags: flags, skippedFrames: 128),
              )!
              as XitaAudio;
      expect(token.frames, 128);
      expect(token.samples, isEmpty);
    }
  });
  test('NTP era wrap resolves against explicit wall anchor, within one microsecond', () {
    for (final year in [2026, 2037, 2100]) {
      final now = DateTime.utc(year, 5, 2, 3, 4, 5, 678, 901);
      final packet =
          XitaPacket.decode(
                XitaDescriptor.encode(
                  sampleRate: 48000,
                  channels: 2,
                  periodFrames: 1024,
                  frame: 0xffffffff,
                  timestamp: now,
                ),
              )!
              as XitaDescriptor;
      expect(packet.timestampNear(now).difference(now).inMicroseconds.abs(), lessThanOrEqualTo(1));
    }
  });
  test('clock removes sender delay, unwraps counters and ignores reordered observations', () {
    final clock = XitaClock(48000);
    clock.observe(audio(0xfffffff0, delay: 148), 1000148);
    expect(clock.presentationMicros(0xfffffff0), 1150000);
    expect(clock.presentationMicros(32), 1151000);
    clock.observe(audio(32, flags: 0), 1001100);
    clock.observe(audio(0xfffffff0), 9000000);
    expect(clock.presentationMicros(32), 1151000);
    expect(XitaClock.delta(32, 0xfffffff0), 48);
  });
  test('clock rejects outlier leaps and bounds long-running drift correction', () {
    final clock = XitaClock(48000);
    clock.observe(audio(0), 0);
    for (var second = 1; second <= 100; second++) {
      clock.observe(audio(second * 48000), second * 1000100);
    }
    expect(clock.rateRatio, inInclusiveRange(.998, 1.002));
    final before = clock.presentationMicros(101 * 48000);
    clock.observe(audio(101 * 48000), 999000000);
    expect(clock.presentationMicros(101 * 48000), before);
    expect(() => XitaClock(0), throwsArgumentError);
    expect(() => XitaClock(44100).presentationMicros(0), throwsStateError);
  });
}
