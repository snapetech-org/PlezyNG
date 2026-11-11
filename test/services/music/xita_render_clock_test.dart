import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/caldera_audio_sink.dart';
import 'package:plezy/services/music/xita_packet.dart';
import 'package:plezy/services/music/xita_output_clock.dart';

void main() {
  for (final deviceDelay in [20000, 50000, 80000]) {
    test('audible render aligns source impulse with $deviceDelay us device delay and independent drift', () {
      const rate = 8000, sourceRate = 1.001, deviceRate = .999;
      final descriptor =
          XitaPacket.decode(
                XitaDescriptor.encode(
                  sampleRate: rate,
                  channels: 2,
                  periodFrames: 80,
                  frame: 0,
                  timestamp: DateTime.utc(2026),
                ),
              )!
              as XitaDescriptor;
      final buffer = XitaJitterBuffer(descriptor), output = XitaOutputClock(rate);
      var incoming = 0, waveFrame = 0;
      int? impulseWaveFrame;
      for (var now = 0; now <= 2000000; now += 2000) {
        while (incoming * 1000000 / rate / sourceRate <= now) {
          final samples = Float32List(160);
          for (var f = 0; f < 80; f++) {
            final value = incoming + f >= 8000 && incoming + f < 8400 ? 1.0 : 0.0;
            samples[f * 2] = samples[f * 2 + 1] = value;
          }
          buffer.add(
            XitaPacket.decode(XitaAudio.encode(frame: incoming, channels: 2, samples: samples, flags: 1))! as XitaAudio,
            (incoming * 1000000 / rate / sourceRate).round(),
          );
          incoming += 80;
        }
        if (now >= 100000 && now % 20000 == 0) {
          output.observe(Duration(microseconds: ((now - deviceDelay) * deviceRate).round()), now);
        }
        if (!output.ready) {
          waveFrame = (now * rate / 1000000).floor();
          continue;
        }
        final end = (output.frameAtMicros(now) + deviceDelay * rate / 1000000).floor();
        final frames = end - waveFrame;
        if (frames <= 0) continue;
        final rendered = ByteData.sublistView(
          buffer.renderScheduled(
            frames,
            presentationMicros: output.presentationMicros(waveFrame),
            microsPerFrame: output.microsPerFrame,
          ),
        );
        for (var f = 0; f < frames; f++) {
          if (impulseWaveFrame == null && rendered.getFloat32(f * 8, Endian.little) > .9) {
            impulseWaveFrame = waveFrame + f;
          }
        }
        waveFrame = end;
      }
      expect(impulseWaveFrame, isNotNull);
      final actuallyAudible = deviceDelay + impulseWaveFrame! * 1000000 / rate / deviceRate;
      final sourcePresentation = 8000 * 1000000 / rate / sourceRate + 150000;
      expect(actuallyAudible, closeTo(sourcePresentation, 2000));
      expect(buffer.droppedPackets, 0);
    });
  }
  test('scheduled interpolation remains continuous across the 32-bit source counter wrap', () {
    final descriptor =
        XitaPacket.decode(
              XitaDescriptor.encode(
                sampleRate: 8000,
                channels: 2,
                periodFrames: 80,
                frame: 0xffffffb0,
                timestamp: DateTime.utc(2026),
              ),
            )!
            as XitaDescriptor;
    final buffer = XitaJitterBuffer(descriptor);
    for (final (frame, value, time) in [(0xffffffb0, -.5, 0), (0, .5, 10000)]) {
      buffer.add(
        XitaPacket.decode(
              XitaAudio.encode(
                frame: frame,
                channels: 2,
                samples: Float32List.fromList(List.filled(160, value)),
                flags: 1,
              ),
            )!
            as XitaAudio,
        time,
      );
    }
    final bytes = ByteData.sublistView(
      buffer.renderScheduled(2, presentationMicros: 150000 + 79.5 * 125, microsPerFrame: 125),
    );
    expect(bytes.getFloat32(0, Endian.little), closeTo(0, 1e-6));
    expect(bytes.getFloat32(8, Endian.little), closeTo(.5, 1e-6));
  });
}
