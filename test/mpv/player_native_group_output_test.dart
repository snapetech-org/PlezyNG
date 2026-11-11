import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/player_native.dart';
import '../test_helpers/mock_player_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('group speaker renders on a third independent audio-only core', () async {
    final commands = <List<dynamic>>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['com.plezy/mpv_audio_player', 'com.plezy/mpv_audio_player/overlap']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(MethodChannel(name), null));
    }
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_audio_player/group_output',
      eventChannelName: 'com.plezy/mpv_audio_player/group_output/events',
      methodHandler: (call) async {
        if (call.method == 'initialize') return true;
        if (call.method == 'command') {
          commands.add(List<dynamic>.from((call.arguments as Map)['args'] as List));
        }
        return null;
      },
      testBody: () async {
        final speaker = PlayerNative.audioGroupOutput();
        final primary = PlayerNative.audio();
        final overlap = PlayerNative.audio(overlap: true);
        try {
          expect(speaker.audioOnly, isTrue);
          expect(speaker.methodChannel.name, 'com.plezy/mpv_audio_player/group_output');
          expect(speaker.eventChannel.name, 'com.plezy/mpv_audio_player/group_output/events');
          expect({speaker.methodChannel.name, primary.methodChannel.name, overlap.methodChannel.name}, hasLength(3));
          await speaker.open(const Media('http://127.0.0.1:12222/generated.wav'), isLive: true);
          expect(commands.where((command) => command.first == 'loadfile'), hasLength(1));
          expect(speaker.nativeVisualizationAudioReady, isTrue);
        } finally {
          await speaker.dispose();
          await primary.dispose();
          await overlap.dispose();
        }
      },
    );
  });
}
