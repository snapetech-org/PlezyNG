import 'dart:async';

import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/services/music/cast_music_player.dart';
import 'package:plezy/services/music/cast_music_output.dart';
import 'package:plezy/services/music/music_source_resolver.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/playback_initialization_service.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/music_experience_fakes.dart';

class _CastConnection extends GoogleCastSession {
  _CastConnection(String? session, String device, {GoogleCastConnectState state = GoogleCastConnectState.connected})
    : super(
        sessionID: session,
        connectionState: state,
        currentDeviceMuted: false,
        currentDeviceVolume: 1,
        deviceStatusText: '',
        device: GoogleCastDevice(
          deviceID: device,
          friendlyName: 'Speaker',
          modelName: null,
          statusText: null,
          deviceVersion: '',
          isOnLocalNetwork: true,
          category: '',
          uniqueID: device,
        ),
      );
}

class _SourceClient extends ExperienceClient {
  Completer<ExternalPlaybackTarget?>? target;
  @override
  Future<ExternalPlaybackTarget?> resolveExternalPlayback(
    MediaItem item, {
    int mediaIndex = 0,
    String? mediaSourceId,
    Duration? position,
  }) async =>
      target == null ? const ExternalPlaybackTarget(url: 'https://server/file.flac?auth=private') : target!.future;
}

class _Receiver implements CastMusicReceiver {
  final updates = StreamController<CastMusicStatus>.broadcast(sync: true);
  final ticks = StreamController<Duration>.broadcast(sync: true);
  final links = StreamController<bool>.broadcast(sync: true);
  @override
  bool connected = true;
  @override
  CastMusicStatus? status;
  @override
  Stream<CastMusicStatus> get statuses => updates.stream;
  @override
  Stream<Duration> get positions => ticks.stream;
  @override
  Stream<bool> get connections => links.stream;
  final calls = <String>[];
  String? token;
  int session = 0;
  bool acknowledgeLoads = true;
  CastMusicState loadState = CastMusicState.paused;

  void emit(CastMusicState state, {String? owner, int? sessionId}) {
    status = CastMusicStatus(
      session: sessionId ?? session,
      token: owner ?? token,
      state: state,
      duration: const Duration(minutes: 3),
    );
    updates.add(status!);
  }

  @override
  Future<void> load(MediaItem track, MusicSource source, Media media, String token) async {
    calls.add('load:${track.id}');
    this.token = token;
    session++;
    if (acknowledgeLoads) emit(loadState);
  }

  @override
  Future<void> play() async {
    calls.add('play');
    emit(CastMusicState.playing);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    emit(CastMusicState.paused);
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    emit(CastMusicState.stopped);
  }

  @override
  Future<void> seek(Duration position) async => calls.add('seek:${position.inSeconds}');
  @override
  Future<void> setVolume(double volume) async => calls.add('volume:$volume');
  @override
  Future<void> setRate(double rate) async => calls.add('rate:$rate');

  Future<void> close() async {
    await updates.close();
    await ticks.close();
    await links.close();
  }
}

void main() {
  test('Cast ownership keys distinguish receiver changes and new connections', () {
    final key = castReceiverKey(_CastConnection('session', 'speaker'));
    expect(key, (session: 'session', device: 'speaker'));
    expect(castReceiverKey(_CastConnection('session', 'speaker')), key);
    expect(castReceiverKey(_CastConnection('session', 'different')), isNot(key));
    expect(castReceiverKey(_CastConnection('new-session', 'speaker')), isNot(key));
    expect(castReceiverKey(_CastConnection(null, 'speaker')), isNull);
    expect(castReceiverKey(_CastConnection('session', 'speaker', state: GoogleCastConnectState.connecting)), isNull);
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  final track = testMediaItem(id: 'track', kind: MediaKind.track, serverId: 'server', durationMs: 180000);
  const source = MusicSource(url: 'https://server/audio.flac?token=secret');
  late _Receiver receiver;
  late CastMusicPlayer player;
  var authorized = true;
  var sourceCurrent = true;

  setUp(() {
    authorized = true;
    sourceCurrent = true;
    receiver = _Receiver();
    player = CastMusicPlayer(receiver, authorized: () => authorized);
    player.prepare(track, source, () => sourceCurrent);
  });
  tearDown(() async {
    await player.dispose();
    await receiver.close();
  });

  test('paused preparation waits for ownership and preserves the playhead', () async {
    await player.open(Media(source.url, start: const Duration(seconds: 45)), play: false);
    expect(receiver.calls, ['load:track']);
    expect(player.state.playing, isFalse);
    expect(player.currentPosition, const Duration(seconds: 45));
    expect(player.state.duration, const Duration(minutes: 3));
    await player.play();
    await player.pause();
    await player.seek(const Duration(seconds: 60));
    await player.setVolume(45);
    await player.setRate(1.25);
    expect(receiver.calls, ['load:track', 'play', 'pause', 'seek:60', 'volume:45.0', 'rate:1.25']);
  });

  test('foreign sender revokes control without stopping or adopting foreign media', () async {
    await player.open(Media(source.url));
    receiver.ticks.add(const Duration(seconds: 20));
    var revoked = 0;
    final subscription = player.revoked.listen((_) => revoked++);
    receiver.emit(CastMusicState.playing, owner: 'foreign', sessionId: 900);
    receiver.ticks.add(const Duration(seconds: 90));
    await player.play();
    await player.pause();
    await player.stop();
    expect(revoked, 1);
    expect(player.currentPosition, const Duration(seconds: 20));
    expect(receiver.calls, ['load:track', 'play']);
    await subscription.cancel();
  });

  test('finished receiver status emits one EOF and ignores its zero-position reset', () async {
    await player.open(Media(source.url));
    final completed = <bool>[];
    final subscription = player.streams.completed.listen(completed.add);
    receiver.emit(CastMusicState.finished);
    receiver.ticks.add(Duration.zero);
    receiver.emit(CastMusicState.finished);
    await pumpEventQueue();
    expect(completed.where((value) => value), hasLength(1));
    expect(player.currentPosition, const Duration(minutes: 3));
    await subscription.cancel();
  });

  test('authentication revocation blocks commands but permits stopping only the owned media', () async {
    await player.open(Media(source.url));
    authorized = false;
    await player.play();
    await player.stop();
    expect(player.available, isFalse);
    expect(receiver.calls, ['load:track', 'play', 'stop']);
  });

  test('disconnect revokes even without a media status update', () async {
    await player.open(Media(source.url));
    receiver.connected = false;
    receiver.links.add(false);
    expect(player.available, isFalse);
    await player.stop();
    expect(receiver.calls, ['load:track', 'play']);
  });

  test('source revocation before preparation cannot dispatch credentials', () async {
    sourceCurrent = false;
    await expectLater(player.open(Media(source.url)), throwsStateError);
    expect(receiver.calls, isEmpty);
  });

  test('local paths and header-dependent sources are rejected', () async {
    const local = MusicSource(url: 'file:///private/cache/music.flac');
    player.prepare(track, local, () => true);
    await expectLater(player.open(Media(local.url)), throwsStateError);
    const protected = MusicSource(url: 'https://server/music', headers: {'Authorization': 'secret'});
    player.prepare(track, protected, () => true);
    await expectLater(player.open(Media(protected.url, headers: protected.headers)), throwsStateError);
    expect(receiver.calls, isEmpty);
  });

  test('receiver load rejection never begins audible playback', () async {
    receiver.loadState = CastMusicState.error;
    await expectLater(player.open(Media(source.url)), throwsStateError);
    expect(receiver.calls, ['load:track']);
  });

  test('disposing a pending acknowledgement releases it without starting playback', () async {
    receiver.acknowledgeLoads = false;
    final opening = player.open(Media(source.url));
    final failure = expectLater(opening, throwsStateError);
    await pumpEventQueue();
    await player.dispose();
    await failure;
    expect(receiver.calls, ['load:track']);
  });

  test('audio content types do not inherit the video default', () {
    expect(castMusicContentType(Uri.parse(source.url)), 'audio/flac');
    expect(castMusicContentType(Uri.parse('https://server/song.opus')), 'audio/ogg');
    expect(castMusicContentType(Uri.parse('https://server/stream.m3u8')), 'application/vnd.apple.mpegurl');
    expect(castMusicContentType(Uri.parse('https://server/parts/1/file'), container: 'flac'), 'audio/flac');
  });

  test('Cast resolves through the receiver URL adapter instead of local caches', () async {
    final client = _SourceClient();
    final manager = MultiServerManager()..debugRegisterClientForTesting(client);
    final output = CastMusicOutput(
      name: 'receiver',
      serverManager: manager,
      authorized: () => true,
      receiver: receiver,
    );
    addTearDown(() async {
      await output.player.dispose();
      manager.dispose();
    });
    final resolved = await output.resolve(musicTrack('one'));
    expect(resolved.url, 'https://server/file.flac?auth=private');
    expect(resolved.headers, isNull);
    expect(resolved.reportingClient, same(client));
    await output.player.open(Media(resolved.url), play: false);
    expect(receiver.calls, ['load:one']);
  });

  test('Cast resolution rejects account changes before delivering the receiver URL', () async {
    final client = _SourceClient()..target = Completer<ExternalPlaybackTarget?>();
    final manager = MultiServerManager()..debugRegisterClientForTesting(client);
    final output = CastMusicOutput(
      name: 'receiver',
      serverManager: manager,
      authorized: () => true,
      receiver: receiver,
    );
    addTearDown(() async {
      await output.player.dispose();
      manager.dispose();
    });
    final resolving = output.resolve(musicTrack('one'));
    final rejected = expectLater(resolving, throwsStateError);
    client.authenticationSessionId = Object();
    client.target!.complete(const ExternalPlaybackTarget(url: 'https://server/private'));
    await rejected;
    expect(receiver.calls, isEmpty);
  });
}
