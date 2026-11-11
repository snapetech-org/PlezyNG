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
    expect(() => mixer.add('bad', block(channels: 3), position: Duration.zero, gain: 1), throwsFormatException);
    expect(() => mixer.add('bad', block(), position: Duration.zero, gain: double.nan), throwsFormatException);
  });

  for (final width in [6, 8]) {
    test('canonical $width channels preserve speaker order and independent overlap gain', () {
      final samples = Float32List.fromList(List.generate(width * 4, (i) => .05 * (i % width + 1)));
      final input = MusicPcmBlock(
        presentationTime: Duration.zero,
        sampleRate: 48000,
        channels: width,
        samples: samples,
        droppedFrames: 0,
        generation: 1,
      );
      final mixer = XitaPcmMixer(channels: width);
      mixer.add('a', input, position: Duration.zero, gain: 1);
      mixer.add('b', input, position: Duration.zero, gain: -.0);
      expect(mixer.render(4), samples);
      expect(mixer.cursor, 4);
    });
  }
  test('5.1 side routing expands to 7.1 with silent side channels; 7.1 folds sides into rear', () {
    final six = XitaPcmMixer(channels: 8);
    six.add('a', block(channels: 6, frames: 1), position: Duration.zero, gain: 1);
    expect(six.render(1), [.5, .5, .5, .5, .5, .5, 0, 0]);
    final eight = XitaPcmMixer(channels: 6);
    eight.add(
      'a',
      MusicPcmBlock(
        presentationTime: Duration.zero,
        sampleRate: 48000,
        channels: 8,
        samples: Float32List.fromList([.1, .2, .3, .4, .5, .6, -.5, -.6]),
        droppedFrames: 0,
        generation: 1,
      ),
      position: Duration.zero,
      gain: 1,
    );
    final result = eight.render(1);
    expect(result.sublist(0, 4), [.1, .2, .3, .4].map((n) => Float32List.fromList([n]).first));
    expect(result.sublist(4), [0, 0]);
  });
  test('surround stereo fold preserves headroom and excludes LFE', () {
    final mixer = XitaPcmMixer();
    mixer.add(
      'a',
      MusicPcmBlock(
        presentationTime: Duration.zero,
        sampleRate: 48000,
        channels: 8,
        samples: Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 0]),
        droppedFrames: 0,
        generation: 1,
      ),
      position: Duration.zero,
      gain: 1,
    );
    expect(mixer.render(1), [0, 0]);
    mixer.add('a', block(channels: 8, frames: 1, value: 1), position: Duration.zero, gain: 1);
    expect(mixer.render(1), [1, 1]);
  });
  test('a decoder layout change retires stale surround PCM on every output bus', () {
    for (final width in [2, 6, 8]) {
      final mixer = XitaPcmMixer(channels: width);
      mixer.add('a', block(channels: 8, frames: 10), position: Duration.zero, gain: 1);
      mixer.render(1);
      mixer.add('a', block(channels: 2, frames: 1, value: -.5), position: Duration.zero, gain: 1);
      expect(mixer.render(1), [-.5, -.5, ...List.filled(width - 2, 0)]);
      expect(mixer.render(1), everyElement(0));
    }
  });
  test('invalid input cannot partially overwrite accepted PCM', () {
    final mixer = XitaPcmMixer(channels: 8);
    mixer.add('a', block(channels: 8, frames: 4), position: Duration.zero, gain: 1);
    final invalid = block(channels: 8, frames: 4)..samples[31] = double.nan;
    expect(() => mixer.add('a', invalid, position: Duration.zero, gain: 1), throwsFormatException);
    expect(mixer.render(4), everyElement(.5));
  });
}
