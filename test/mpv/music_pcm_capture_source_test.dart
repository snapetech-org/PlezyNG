import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/music_pcm_capture_source.dart';
import 'package:plezy/mpv/player/player_native.dart';
import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';

Map<String, Object> packet({List<double> samples = const [.25, -.25], int generation = 3}) {
  final data = ByteData(samples.length * 4);
  for (var i = 0; i < samples.length; i++) {
    data.setFloat32(i * 4, samples[i], Endian.host);
  }
  return {
    'presentationTimeUs': 1000000,
    'sampleRate': 44100,
    'channels': 2,
    'droppedFrames': 0,
    'generation': generation,
    'encoding': 'float32',
    'pcm': data.buffer.asUint8List(),
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetSharedPreferencesForTest);
  test('decodes native PCM with timing and generation, clamps finite samples', () {
    final block = MusicPcmBlock.parse(packet(samples: [2, -2]))!;
    expect(block.presentationTime, const Duration(seconds: 1));
    expect(block.generation, 3);
    expect(block.frames, 1);
    expect(block.samples, [1, -1]);
    expect(MusicPcmBlock.parse(packet(samples: [double.nan, 0])), isNull);
    expect(MusicPcmBlock.parse(packet(samples: [double.infinity, 0])), isNull);
    for (final invalid in <Map<String, Object>>[
      {'channels': 0},
      {'channels': 9},
      {'sampleRate': 7999},
      {'sampleRate': 384001},
      {'generation': -1},
      {'droppedFrames': -1},
      {'presentationTimeUs': -1},
      {'encoding': 'int16'},
      {'pcm': Uint8List(3)},
      {'pcm': Uint8List(513 * 8)},
    ]) {
      expect(MusicPcmBlock.parse({...packet(), ...invalid}), isNull, reason: '$invalid');
    }
  });
  test('ordered music capture uses audio channel and releases its lease on disposal', () async {
    final calls = <MethodCall>[];
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_audio_player',
      eventChannelName: 'com.plezy/mpv_audio_player/events',
      methodHandler: (call) async {
        calls.add(call);
        return switch (call.method) {
          'initialize' || 'musicPcmCaptureAvailable' || 'setMusicPcmCaptureEnabled' => true,
          'drainMusicPcmCapture' => [
            packet(),
            {'encoding': 'invalid'},
          ],
          _ => null,
        };
      },
      testBody: () async {
        final player = PlayerNative.audio();
        expect(await player.musicPcmCaptureAvailable(), isTrue);
        expect(await player.setMusicPcmCaptureEnabled(true), isTrue);
        final blocks = await player.drainMusicPcmCapture();
        expect(blocks.single.generation, 3);
        expect(calls.last.arguments, containsPair('presentationTimeUs', 0));
        await player.dispose();
        final toggles = calls.where((c) => c.method == 'setMusicPcmCaptureEnabled').toList();
        expect(toggles.map((c) => (c.arguments as Map)['enabled']), [true, false]);
        expect(await player.drainMusicPcmCapture(), isEmpty);
      },
    );
  });
  test('late drain cannot publish PCM after capture is disabled', () async {
    final drained = Completer<Object?>();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_audio_player',
      eventChannelName: 'com.plezy/mpv_audio_player/events',
      methodHandler: (call) async => switch (call.method) {
        'initialize' || 'musicPcmCaptureAvailable' || 'setMusicPcmCaptureEnabled' => true,
        'drainMusicPcmCapture' => drained.future,
        _ => null,
      },
      testBody: () async {
        final player = PlayerNative.audio();
        try {
          await player.musicPcmCaptureAvailable();
          await player.setMusicPcmCaptureEnabled(true);
          final pending = player.drainMusicPcmCapture();
          await Future<void>.delayed(Duration.zero);
          await player.setMusicPcmCaptureEnabled(false);
          drained.complete([packet()]);
          expect(await pending, isEmpty);
        } finally {
          await player.dispose();
        }
      },
    );
  });
  test('video and absent optional capture cannot claim an audio tap', () async {
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_audio_player',
      eventChannelName: 'com.plezy/mpv_audio_player/events',
      testBody: () async {
        final audio = PlayerNative.audio(), video = PlayerNative();
        try {
          expect(await video.musicPcmCaptureAvailable(), isFalse);
          expect(await audio.musicPcmCaptureAvailable(), isFalse);
          expect(await audio.setMusicPcmCaptureEnabled(true), isFalse);
          expect(await audio.drainMusicPcmCapture(), isEmpty);
        } finally {
          await audio.dispose();
          await video.dispose();
        }
      },
    );
  });
}
