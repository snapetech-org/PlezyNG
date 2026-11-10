import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/services/music/music_audio_policy.dart';

class Output implements Player, AudioEqualizerCapable {
  final Map<String, String> properties = {};
  List<double>? bands;
  String devices = '[]';
  @override
  Future<String?> getProperty(String name) async => name == 'audio-device-list' ? devices : properties[name];
  @override
  Future<void> setAudioDevice(AudioDevice device) async {
    properties['audio-device'] = device.name;
  }

  bool? passthrough, compression;
  @override
  String get playerType => 'mpv';
  @override
  Future<void> setProperty(String name, String value) async {
    properties[name] = value;
  }

  @override
  Future<void> setAudioPassthrough(bool enabled) async {
    passthrough = enabled;
  }

  @override
  Future<void> setAudioNormalization(bool enabled) async {
    compression = enabled;
  }

  @override
  Future<void> setAudioEqualizer(List<double> gains) async {
    bands = gains;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('automatic leveling follows album context with peak protection', () async {
    final output = Output();
    const policy = MusicAudioPolicy(leveling: MusicLeveling.automatic, exclusive: true, sampleRate: 96000);
    await policy.apply(output, albumContext: true);
    expect(output.properties['replaygain'], 'album');
    expect(output.properties['replaygain-clip'], 'no');
    expect(output.properties['audio-samplerate'], '96000');
    expect(output.properties['audio-exclusive'], 'yes');
    expect(output.compression, isFalse);
    expect(output.passthrough, isFalse);
    await policy.apply(output, albumContext: false);
    expect(output.properties['replaygain'], 'track');
  });
  test('EQ headroom includes preamp and overlapping positive gains', () {
    const p = MusicAudioPolicy(preampDb: -6, bands: [3, 3, 0, 0, 0, 0, 0, 0, 0, 0]);
    expect(p.gain, closeTo(0.2511886, 0.000001));
    expect(MusicAudioPolicy.fromJson(p.toJson()).toJson(), p.toJson());
  });
  test('GraphicEQ log interpolation is bounded and invalid data is rejected', () {
    final bands = MusicAudioPolicy.parseGraphicEq('GraphicEQ: 20 -6; 20000 6');
    expect(bands, hasLength(10));
    expect(bands.first, lessThan(bands.last));
    expect(MusicAudioPolicy.parseGraphicEq('20 30; 20000 30'), everyElement(12));
    for (final input in ['20 NaN; 20000 0', '20 0; 20 1', '20 0', '20 0; -1 0']) {
      expect(() => MusicAudioPolicy.parseGraphicEq(input), throwsFormatException);
    }
  });
  test('invalid hardware and DSP configurations are rejected', () {
    for (final p in [
      const MusicAudioPolicy(sampleRate: 12345),
      const MusicAudioPolicy(preampDb: 1),
      const MusicAudioPolicy(cacheMiB: 1024),
      const MusicAudioPolicy(bands: [0, 1]),
      const MusicAudioPolicy(output: 'a\nb'),
    ]) {
      expect(p.validate, throwsArgumentError);
    }
  });
  test('an unplugged preferred output falls back to auto and returns when enumerated', () async {
    final output = Output();
    const policy = MusicAudioPolicy(output: 'alsa/usb');
    await policy.apply(output, albumContext: false);
    expect(output.properties['audio-device'], 'auto');
    output.devices = '[{"name":"alsa/usb","description":"USB DAC"}]';
    await policy.apply(output, albumContext: false);
    expect(output.properties['audio-device'], 'alsa/usb');
  });
}
