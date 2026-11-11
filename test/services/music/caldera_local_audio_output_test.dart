import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/caldera_local_audio_output.dart';
import 'music_playback_service_test.dart' show FakePlayer;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final source = Uri.parse('http://127.0.0.1:12345/opaque.wav');
  test('source renderer opens only live PCM without claiming the queue focus', () async {
    final player = FakePlayer();
    addTearDown(player.closeControllers);
    final owner = Object();
    final output = CalderaLocalAudioOutput(
      createPlayer: () => player,
      current: () => true,
      onFailed: () => fail('unexpected failure'),
      configure: (player, current) async {
        await player.setVolume(100);
      },
    );
    expect(await output.openCalderaAudio(owner, source, 'Speaker', () => true), isTrue);
    expect(output.ownsCalderaAudio(owner), isTrue);
    expect(player.audioFocusChanges, [false]);
    expect(player.audioFocusRequests, 0);
    expect(player.openedUris, [source.toString()]);
    expect(player.audioPolicyProperties, containsPair('replaygain', 'no'));
    expect(player.audioPolicyProperties, containsPair('audio-exclusive', 'no'));
    expect(player.audioPolicyProperties, containsPair('cache', 'no'));
    expect(player.audioPolicyProperties, containsPair('demuxer-lavf-probe-info', 'no'));
    expect(player.volumes, [100]);
    await output.closeCalderaAudio(Object());
    expect(player.disposed, isFalse);
    await output.closeCalderaAudio(owner);
    expect(player.disposed, isTrue);
  });

  test('source retirement during configuration prevents the WAV open', () async {
    final player = FakePlayer();
    addTearDown(player.closeControllers);
    final gate = Completer<void>(), entered = Completer<void>(), owner = Object();
    final output = CalderaLocalAudioOutput(
      createPlayer: () => player,
      current: () => true,
      onFailed: () {},
      configure: (_, current) async {
        entered.complete();
        await gate.future;
      },
    );
    final opening = output.openCalderaAudio(owner, source, 'Speaker', () => true);
    await entered.future;
    await output.closeCalderaAudio(owner);
    gate.complete();
    expect(await opening, isFalse);
    expect(player.openedUris, isEmpty);
    expect(player.disposed, isTrue);
  });

  test('configuration failure disposes the unaccepted rendering core', () async {
    final player = FakePlayer();
    addTearDown(player.closeControllers);
    final output = CalderaLocalAudioOutput(
      createPlayer: () => player,
      current: () => true,
      onFailed: () {},
      configure: (_, current) async => throw StateError('output unavailable'),
    );
    await expectLater(output.openCalderaAudio(Object(), source, 'Speaker', () => true), throwsStateError);
    expect(player.disposed, isTrue);
    expect(player.openedUris, isEmpty);
  });

  test('renderer completion retires only its own output and reports failure', () async {
    final player = FakePlayer();
    addTearDown(player.closeControllers);
    var failures = 0;
    final owner = Object();
    final output = CalderaLocalAudioOutput(
      createPlayer: () => player,
      current: () => true,
      onFailed: () => failures++,
      configure: (_, current) async {},
    );
    await output.openCalderaAudio(owner, source, 'Speaker', () => true);
    player.emitCompleted();
    await pumpEventQueue();
    expect(output.ownsCalderaAudio(owner), isFalse);
    expect(player.disposed, isTrue);
    expect(failures, 1);
  });

  test('late audible clock reads cannot cross the renderer owner', () async {
    final player = FakePlayer()..nativeClock = true;
    addTearDown(player.closeControllers);
    final owner = Object(), gate = Completer<String?>();
    final output = CalderaLocalAudioOutput(
      createPlayer: () => player,
      current: () => true,
      onFailed: () {},
      configure: (_, current) async {},
    );
    await output.openCalderaAudio(owner, source, 'Speaker', () => true);
    player.audibleClock = gate;
    final pending = output.readCalderaAudioClock(owner);
    await output.closeCalderaAudio(owner);
    gate.complete('1.25');
    expect(await pending, isNull);
    expect(output.hasCalderaAudioClock(owner), isFalse);
  });

  test('arbitrary network resources cannot create a source renderer', () async {
    var created = 0;
    final output = CalderaLocalAudioOutput(
      createPlayer: () {
        created++;
        return FakePlayer();
      },
      current: () => true,
      onFailed: () {},
      configure: (_, current) async {},
    );
    for (final url in ['https://127.0.0.1/a', 'http://192.168.1.2/a', 'file:///a']) {
      expect(await output.openCalderaAudio(Object(), Uri.parse(url), '', () => true), isFalse);
    }
    expect(created, 0);
  });
}
