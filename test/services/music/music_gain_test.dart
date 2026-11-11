import 'dart:async';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/music_gain.dart';

void main() {
  test('native volume keeps its cubic user curve and applies equal-power fades linearly', () {
    for (final volume in [25.0, 50.0, 100.0]) {
      final base = musicCaptureGain(volume, nativeCubic: true);
      for (final progress in [0.0, .25, .5, .75, 1.0]) {
        final left = musicCaptureGain(
          musicVolumeForGain(volume, math.cos(progress * math.pi / 2), nativeCubic: true),
          nativeCubic: true,
        );
        final right = musicCaptureGain(
          musicVolumeForGain(volume, math.sin(progress * math.pi / 2), nativeCubic: true),
          nativeCubic: true,
        );
        expect(left * left + right * right, closeTo(base * base, 1e-9));
      }
    }
    expect(musicCaptureGain(50, nativeCubic: true), .125);
    expect(musicCaptureGain(50, nativeCubic: false), .5);
    expect(musicVolumeForGain(50, .5, nativeCubic: false), 25);
  });
  test('native track/album gain, preamp, clipping and missing tags match AO semantics', () async {
    final values = <String, String?>{
      'replaygain': 'track',
      'volume-gain': '0',
      'replaygain-fallback': '-6.020599913279624',
      'current-tracks/audio/replaygain-track-gain': '-6.020599913279624',
      'current-tracks/audio/replaygain-track-peak': '1',
      'current-tracks/audio/replaygain-album-gain': '-12.041199826559248',
      'current-tracks/audio/replaygain-album-peak': '1',
      'replaygain-preamp': '0',
      'replaygain-clip': 'no',
    };
    final reader = NativeMusicPcmGainReader((key) async => values[key]);
    expect(await reader.read(1), closeTo(.5, 1e-9));
    values['replaygain'] = 'album';
    expect(await reader.read(2), closeTo(.25, 1e-9));
    values['replaygain-preamp'] = '18.06179973983887';
    expect(await reader.read(3), closeTo(1, 1e-9), reason: 'Clipping prevention limits gain using the selected peak');
    values['replaygain-clip'] = 'yes';
    expect(await reader.read(4), closeTo(2, 1e-9));
    values['current-tracks/audio/replaygain-album-gain'] = null;
    expect(
      await reader.read(5),
      closeTo(.5, 1e-9),
      reason: 'Missing native tags use configured fallback without tag preamp',
    );
    values['replaygain'] = 'no';
    values['volume-gain'] = '6.020599913279624';
    expect(await reader.read(6), closeTo(1, 1e-9), reason: 'Additional AO gain remains separate from ReplayGain');
    values['volume-gain'] = 'NaN';
    await expectLater(reader.read(7), throwsFormatException);
  });
  test('a late previous track gain read cannot replace the new revision cache', () async {
    final old = Completer<String?>();
    var revision = 0, reads = 0;
    final reader = NativeMusicPcmGainReader((key) async {
      reads++;
      if (key == 'volume-gain' && revision == 0) return old.future;
      if (key == 'volume-gain') return '-6.020599913279624';
      return key == 'replaygain' ? 'no' : null;
    });
    final first = reader.read('old');
    revision = 1;
    expect(await reader.read('new'), closeTo(.5, 1e-9));
    old.complete('6.020599913279624');
    expect(await first, closeTo(2, 1e-9));
    final before = reads;
    expect(await reader.read('new'), closeTo(.5, 1e-9));
    expect(reads, before);
  });
}
