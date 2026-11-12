import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/music_system_audio_routes.dart';

Map<String, Object> route({String name = 'Selected speaker'}) => {
  'version': 1,
  'outputs': [
    {'id': 'stable-system-id', 'name': name, 'type': 'BluetoothA2DPOutput', 'bluetooth': true, 'channels': 2},
  ],
  'sampleRate': 48000.0,
  'outputChannels': 2,
  'outputLatencyMs': 90.0,
  'ioBufferMs': 5.0,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('com.pleazyng/music_audio_route');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  test('selected OS route retains stable identity without becoming an available-device list', () {
    final value = MusicSystemAudioRoute.fromMessage(route());
    expect(value.outputs.single.id, 'stable-system-id');
    expect(value.outputs.single.name, 'Selected speaker');
    expect(value.outputs.single.bluetooth, isTrue);
    expect(value.sampleRate, 48000);
    expect(value.outputLatencyMs, 90);
    expect(value.ioBufferMs, 5);
    expect(() => value.outputs.clear(), throwsUnsupportedError);
  });

  test('native read is a single inspection call without activation or routing commands', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return route();
    });
    expect((await MusicSystemAudioRoutes.read())!.outputs.single.channels, 2);
    expect(calls.single.method, 'snapshot');
    expect(calls.single.arguments, isNull);
  });

  test('unavailable native route service remains unavailable', () async {
    messenger.setMockMethodCallHandler(methods, (_) async => throw MissingPluginException());
    expect(await MusicSystemAudioRoutes.read(), isNull);
    messenger.setMockMethodCallHandler(methods, (_) async => throw PlatformException(code: 'unavailable'));
    expect(await MusicSystemAudioRoutes.read(), isNull);
  });

  for (final (index, malformed) in [
    <String, Object>{},
    {...route(), 'version': 2},
    {...route(), 'sampleRate': double.nan},
    {...route(), 'outputLatencyMs': double.infinity},
    {...route(), 'ioBufferMs': -1},
    {...route(), 'outputChannels': 2.5},
    {...route(), 'outputs': List.filled(17, (route()['outputs'] as List).single)},
    {...route(), 'outputs': List.filled(2, (route()['outputs'] as List).single)},
    {
      ...route(),
      'outputs': [
        {'id': '', 'name': 'Speaker', 'type': 'x', 'bluetooth': false, 'channels': 2},
      ],
    },
  ].indexed) {
    test('malformed or ambiguous OS route is rejected: $index', () {
      expect(() => MusicSystemAudioRoute.fromMessage(malformed), throwsFormatException);
    });
  }
}
