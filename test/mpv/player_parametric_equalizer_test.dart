import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:plezy/mpv/player/player_native.dart';
import 'package:plezy/mpv/player/player_parametric_equalizer.dart';
import '../test_helpers/mock_player_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('finite bounded numeric equalizer snapshot retains exact parametric bands', () {
    final bands = <PlayerParametricBand>[(filterType: 0, frequency: 1000, gain: 6, q: .7)];
    final copy = PlayerParametricEqualizer(enabled: true, gain: -3.5, bands: bands).snapshot();
    bands.clear();
    expect(copy.bands, hasLength(1));
    expect(copy.filters, ['volume=-3.5dB', 'equalizer=f=1000.0:t=q:w=0.7:g=6.0']);
    expect(() => copy.bands.clear(), throwsUnsupportedError);
    expect(const PlayerParametricEqualizer().filters, isEmpty);
    for (final band in [
      (filterType: 3, frequency: 1000.0, gain: 2.0, q: 1.0),
      (filterType: 0, frequency: double.nan, gain: 2.0, q: 1.0),
      (filterType: 0, frequency: 1000.0, gain: double.infinity, q: 1.0),
      (filterType: 0, frequency: 1000.0, gain: 2.0, q: 0.0),
      (filterType: 0, frequency: 1000.0, gain: 2.0, q: 1000.0),
    ]) {
      expect(() => PlayerParametricEqualizer(bands: [band]).snapshot(), throwsArgumentError);
    }
    expect(() => const PlayerParametricEqualizer(gain: 25).snapshot(), throwsArgumentError);
    expect(() => PlayerParametricEqualizer(bands: List.filled(33, copy.bands.single)).snapshot(), throwsArgumentError);
  });

  test('parametric filters compose with ten-band effects and survive rate changes', () async {
    final filters = <String>[];
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        if (call.method == 'initialize') return true;
        if (call.method == 'setProperty' && (call.arguments as Map)['name'] == 'af') {
          filters.add((call.arguments as Map)['value'] as String);
        }
        return null;
      },
      testBody: () async {
        final player = PlayerNative();
        try {
          await player.setAudioPassthrough(true);
          await player.setParametricEqualizer(
            const PlayerParametricEqualizer(
              enabled: true,
              gain: -3.5,
              bands: [
                (filterType: 0, frequency: 1000, gain: 6, q: .7),
                (filterType: 1, frequency: 100, gain: 2, q: 1),
                (filterType: 2, frequency: 8000, gain: -2, q: .7),
              ],
            ),
          );
          expect(player.audioPassthroughActive, isFalse);
          expect(filters.last, contains('bass=f=100.0:t=q:w=1.0:g=2.0'));
          expect(filters.last, contains('treble=f=8000.0:t=q:w=0.7:g=-2.0'));
          await player.setAudioEqualizer([0, 1, 0, 0, 0, 0, 0, 0, 0, 0]);
          expect(filters.last, contains('equalizer=f=125:t=q:w=1:g=1.0'));
          expect(filters.last, contains('volume=-3.5dB'));
          await player.setRate(1.1);
          await player.setAudioNormalization(true);
          expect(filters.last, contains('volume=-3.5dB'));
          await player.setParametricEqualizer(const PlayerParametricEqualizer());
          expect(filters.last, isNot(contains('volume=-3.5dB')));
          expect(filters.last, contains('equalizer=f=125:t=q:w=1:g=1.0'));
        } finally {
          await player.dispose();
        }
      },
    );
  });

  test('failed native graph restores accepted EQ and does not poison later requests', () async {
    final filters = <String>[];
    var reject = false;
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        if (call.method == 'initialize') return true;
        if (call.method == 'setProperty' && (call.arguments as Map)['name'] == 'af') {
          final value = (call.arguments as Map)['value'] as String;
          filters.add(value);
          if (reject && value.contains('bass=')) {
            reject = false;
            throw PlatformException(code: 'SET_PROPERTY_FAILED');
          }
        }
        return null;
      },
      testBody: () async {
        final player = PlayerNative();
        try {
          await player.setParametricEqualizer(const PlayerParametricEqualizer(enabled: true, gain: -2));
          reject = true;
          final change = player.setParametricEqualizer(
            const PlayerParametricEqualizer(enabled: true, bands: [(filterType: 1, frequency: 100, gain: 2, q: 1)]),
          );
          final failure = expectLater(change, throwsA(isA<PlatformException>()));
          final normalization = player.setAudioNormalization(true);
          await failure;
          await normalization;
          expect(filters.last, contains('volume=-2.0dB'));
          expect(filters.last, isNot(contains('bass=')));
          await player.setParametricEqualizer(const PlayerParametricEqualizer());
          expect(filters.last, isNot(contains('volume=-2.0dB')));
        } finally {
          await player.dispose();
        }
      },
    );
  });
}
