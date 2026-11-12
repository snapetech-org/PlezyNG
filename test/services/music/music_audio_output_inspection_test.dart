import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/caldera_local_audio_output.dart';
import 'package:plezy/services/music/music_audio_output_inspection.dart';

import 'music_playback_service_test.dart' show FakePlayer;

class _Output extends FakePlayer {
  final properties = <String, String>{'audio-device': 'alsa/usb', 'audio-out-params/samplerate': '48000'};
  final requests = <String>[];
  Future<void> Function()? beforeRead;
  @override
  String get playerType => 'mpv';
  @override
  Future<String?> getProperty(String name) async {
    requests.add(name);
    await beforeRead?.call();
    return properties[name];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bounded immutable decoder reports do not fabricate missing hardware fields', () async {
    final player = _Output();
    addTearDown(player.closeControllers);
    player.properties['af'] = 'x' * 4097;
    player.properties['current-ao'] = '';
    final snapshot = await inspectMusicAudioOutput(player, current: () => true);
    expect(snapshot, {'audio-out-params/samplerate': '48000', 'audio-device': 'alsa/usb'});
    expect(() => snapshot.clear(), throwsUnsupportedError);
    expect(await inspectMusicAudioOutput(null, current: () => true), isEmpty);
  });

  test('retirement during a property request discards the whole snapshot', () async {
    final entered = Completer<void>(), finish = Completer<void>();
    var current = true;
    final player = _Output()
      ..beforeRead = () {
        entered.complete();
        return finish.future;
      };
    addTearDown(player.closeControllers);
    final reading = inspectMusicAudioOutput(player, current: () => current);
    await entered.future;
    current = false;
    finish.complete();
    expect(await reading, isEmpty);
    expect(player.requests.length, 1);
  });

  test('a disposed player is not inspected', () async {
    final player = _Output();
    addTearDown(player.closeControllers);
    await player.dispose();
    expect(await inspectMusicAudioOutput(player, current: () => true), isEmpty);
    expect(player.requests, isEmpty);
  });

  test('local group inspection belongs to its physical decoder and retires on close', () async {
    final player = _Output();
    addTearDown(player.closeControllers);
    final owner = Object();
    final output = CalderaLocalAudioOutput(
      createPlayer: () => player,
      configure: (_, current) async {},
      current: () => true,
      onFailed: () => fail('Unexpected output failure'),
    );
    expect(await output.inspectOutput(), isEmpty);
    await output.openCalderaAudio(owner, Uri.parse('http://127.0.0.1:12345/live.wav'), 'Speaker', () => true);
    expect(await output.inspectOutput(), containsPair('audio-device', 'alsa/usb'));
    await output.closeCalderaAudio(owner);
    expect(await output.inspectOutput(), isEmpty);
  });

  test('closing a physical renderer during inspection cannot expose an old report', () async {
    final player = _Output(), entered = Completer<void>(), finish = Completer<void>();
    addTearDown(player.closeControllers);
    final owner = Object();
    final output = CalderaLocalAudioOutput(
      createPlayer: () => player,
      configure: (_, current) async {},
      current: () => true,
      onFailed: () {},
    );
    await output.openCalderaAudio(owner, Uri.parse('http://127.0.0.1:12345/live.wav'), 'Speaker', () => true);
    player.beforeRead = () {
      entered.complete();
      return finish.future;
    };
    final reading = output.inspectOutput();
    await entered.future;
    await output.closeCalderaAudio(owner);
    finish.complete();
    expect(await reading, isEmpty);
  });
}
