import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/music_pcm_capture_source.dart';
import 'package:plezy/services/music/xita_pcm_mixer.dart';

MusicPcmBlock block({
  int rate = 48000,
  int channels = 2,
  int frames = 480,
  int generation = 1,
  int pts = 0,
  double value = .5,
}) => MusicPcmBlock(
  presentationTime: Duration(microseconds: pts),
  sampleRate: rate,
  channels: channels,
  samples: Float32List.fromList(List.filled(frames * channels, value)),
  droppedFrames: 0,
  generation: generation,
);
void main() {
  test('mixed decoders use independent clocks and clip only the final sum', () {
    final mixer = XitaPcmMixer();
    mixer.add('outgoing', block(value: .75), position: Duration.zero, gain: 1);
    mixer.add('incoming', block(value: -.25), position: Duration.zero, gain: 1);
    expect(mixer.render(480), everyElement(.5));
    expect(mixer.render(480), everyElement(0));
  });
  test('gain changes affect already queued PCM without another capture or clipping a lane early', () {
    final mixer = XitaPcmMixer();
    mixer.add('decoder', block(value: .25), position: Duration.zero, gain: 1);
    expect(mixer.render(120), everyElement(.25));
    mixer.setGain('decoder', .5);
    expect(mixer.render(120), everyElement(.125));
    mixer.setGain('decoder', 8);
    expect(mixer.render(120), everyElement(1));
    mixer.setGain('decoder', 0);
    expect(mixer.render(120), everyElement(0));
  });

  test('44.1 kHz mono blocks resample continuously to stereo without a sample gap', () {
    final mixer = XitaPcmMixer();
    for (var i = 0; i < 10; i++) {
      mixer.add(
        'decoder',
        block(rate: 44100, channels: 1, frames: 441, pts: i * 10000),
        position: Duration.zero,
        gain: .5,
      );
    }
    expect(mixer.render(4096), everyElement(.25));
    expect(mixer.render(704), everyElement(.25));
    expect(mixer.render(1), [0, 0]);
  });
  test('native speed processing changes media PTS without resetting the PCM clock', () {
    final mixer = XitaPcmMixer();
    for (var i = 0; i < 8; i++) {
      mixer.add('decoder', block(pts: i * 20000), position: Duration.zero, gain: 1);
    }
    expect(mixer.render(3840), everyElement(.5));
  });

  test('seek generations retire queued audio and rebase to the current wire clock', () {
    final mixer = XitaPcmMixer();
    mixer.add('decoder', block(), position: Duration.zero, gain: 1);
    mixer.render(240);
    mixer.add(
      'decoder',
      block(generation: 2, pts: 10000000, value: -.5),
      position: const Duration(seconds: 10),
      gain: 1,
    );
    expect(mixer.render(480), everyElement(-.5));
  });
  test('future data stays bounded and removing a paused lane silences its queued frames', () {
    final mixer = XitaPcmMixer();
    mixer.add('decoder', block(pts: 50000000), position: Duration.zero, gain: 1);
    expect(mixer.render(4096), everyElement(0));
    mixer.remove('decoder');
    expect(mixer.render(4096), everyElement(0));
    expect(() => mixer.add('bad', block(channels: 8), position: Duration.zero, gain: 1), throwsFormatException);
    expect(() => mixer.add('bad', block(), position: Duration.zero, gain: double.nan), throwsFormatException);
  });
}
