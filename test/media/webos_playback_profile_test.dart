import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/webos_playback_profile.dart';

void main() {
  test('only explicit audio-format rejection permits conversion fallback', () {
    for (final error in [
      'Unsupported audio codec DTS',
      'DTS is not supported',
      'audio format TrueHD not supported',
      'AUDIO_CODEC_NOT_SUPPORTED',
    ]) {
      expect(webosMediaErrorRejectsAudio(error), isTrue, reason: error);
    }
    for (final error in [
      null,
      '',
      'DTS',
      'NDL_media was initialized already',
      'invalid window',
      'network timeout',
      'unsupported video codec HEVC',
      'audio output failed',
      'HTTP 403',
    ]) {
      expect(webosMediaErrorRejectsAudio(error), isFalse, reason: error);
    }
  });
}
