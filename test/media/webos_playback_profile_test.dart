import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/webos_playback_profile.dart';
import 'package:plezy/media/media_source_info.dart';

void main() {
  test('source audio hints describe only an unchanged original rendition', () {
    final audio = MediaAudioTrack(
      id: 101,
      codec: 'dca',
      codecProfile: 'ma',
      channels: 6,
      sampleRate: 48000,
      bitrate: 4000000,
      selected: true,
    );
    final source = MediaSourceInfo(videoUrl: '/file.mkv', audioTracks: [audio], subtitleTracks: [], chapters: []);
    final hints = webosDirectAudioMetadata(source, isTranscoding: false);
    expect(hints.single, containsPair('codecProfile', 'ma'));
    expect(hints.single, containsPair('sampleRate', 48000));
    expect(hints.single, containsPair('bitRate', 4000000));
    expect(webosDirectAudioMetadata(source, isTranscoding: true), isEmpty);
    expect(webosDirectAudioMetadata(null, isTranscoding: false), isEmpty);
    final carried = audio.withSelected(false);
    expect(carried.codecProfile, 'ma');
    expect(carried.sampleRate, 48000);
    expect(carried.bitrate, 4000000);
  });
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
