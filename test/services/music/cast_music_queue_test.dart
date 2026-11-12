import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';

import 'package:flutter/services.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/music/cast_music_queue.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/music/music_queue_controller.dart';
import 'package:plezy/services/music/music_transfer_snapshot.dart';
import 'package:plezy/services/playback_initialization_service.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/music/cast_music_recovery.dart';
import 'package:plezy/services/music/music_library_store.dart';

import '../../test_helpers/music_experience_fakes.dart';

class _Client extends ExperienceClient {
  final resolved = <String>[];
  Future<ExternalPlaybackTarget?> Function(MediaItem)? resolve;

  @override
  Future<ExternalPlaybackTarget?> resolveExternalPlayback(
    MediaItem item, {
    int mediaIndex = 0,
    String? mediaSourceId,
    Duration? position,
  }) async {
    resolved.add(item.id);
    return resolve == null ? ExternalPlaybackTarget(url: 'https://server/${item.id}.flac') : resolve!(item);
  }
}

MusicTransferSnapshot _snapshot({bool playing = true, MusicRepeatMode repeat = MusicRepeatMode.off}) =>
    MusicTransferSnapshot(
      queue: MusicQueueState(
        items: [musicTrack('one'), musicTrack('two'), musicTrack('one')],
        order: [1, 2, 0],
        cursor: 1,
        shuffled: true,
        repeatMode: repeat,
      ),
      position: const Duration(seconds: 12),
      playing: playing,
    );

GoggleCastMediaStatus _status(
  CastMusicQueue queue,
  int index,
  CastMediaPlayerState state, {
  int session = 12,
  GoogleCastMediaRepeatMode repeat = GoogleCastMediaRepeatMode.off,
}) => GoggleCastMediaStatus(
  mediaSessionID: session,
  playerState: state,
  playbackRate: 1,
  volume: 1,
  isMuted: false,
  repeatMode: repeat,
  currentItemId: index + 1,
  mediaInformation: queue.items[index].mediaInformation,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Client client;
  late MultiServerManager manager;

  setUp(() {
    client = _Client();
    manager = MultiServerManager()..debugRegisterClientForTesting(client);
    addTearDown(manager.dispose);
  });

  Future<CastMusicQueue> prepare(MusicTransferSnapshot snapshot) =>
      CastMusicQueue.prepare(snapshot, manager: manager, token: 'test-owner', current: () => true);

  Future<CastMusicQueue> acknowledgedQueue() async {
    final snapshot = _snapshot(playing: false);
    final queue = await prepare(snapshot);
    final events = StreamController<GoggleCastMediaStatus?>.broadcast(sync: true);
    GoggleCastMediaStatus? status;
    try {
      expect(
        await queue.handoff(
          offer: MusicTransferOffer(snapshot, 1, 1, 1, 1),
          current: () => true,
          status: () => status,
          statuses: events.stream,
          invalidated: const Stream.empty(),
          load: (_, _) async {
            status = _status(queue, 1, CastMediaPlayerState.paused);
            events.add(status);
          },
          play: () async {},
          finish: (_) async => true,
        ),
        isTrue,
      );
      return queue;
    } finally {
      await events.close();
    }
  }

  test('restart restores only catalog identities and exact acknowledged ownership', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final original = await acknowledgedQueue();
    const connection = (session: 'native-session', device: 'speaker');
    final persistence = CastMusicRecovery(MusicLibraryStore(db, 'p'), manager);
    await persistence.save(original, connection);
    final restarted = CastMusicRecovery(MusicLibraryStore(db, 'p'), manager);
    final document = (await restarted.read())!;
    expect(jsonEncode(document), isNot(contains('https://')));
    final newClient = _Client();
    final newManager = MultiServerManager()..debugRegisterClientForTesting(newClient);
    addTearDown(newManager.dispose);
    final status = _status(original, 2, CastMediaPlayerState.playing);
    final recovered = CastMusicQueue.recover(document, manager: newManager, connection: connection, status: status)!;
    expect(recovered.matches(connection, connection, status), isTrue);
    expect(recovered.items.every((item) => item.mediaInformation.contentUrl == null), isTrue);
    expect(newClient.resolved, isEmpty);
    final events = StreamController<GoggleCastMediaStatus?>.broadcast(sync: true);
    addTearDown(events.close);
    var current = status;
    expect(
      await recovered.returnToLocal(
        current: () => true,
        status: () => current,
        statuses: events.stream,
        invalidated: const Stream.empty(),
        position: () => const Duration(seconds: 31),
        pause: () async {
          current = _status(original, 2, CastMediaPlayerState.paused);
          events.add(current);
        },
        resume: () async => fail('return succeeded'),
        prepare: (snapshot, _) async {
          expect(snapshot.queue.order, [1, 2, 0]);
          expect(snapshot.queue.items.map((item) => item.id), ['one', 'two', 'one']);
          expect(snapshot.queue.cursor, 2);
          return (position, playing) async => position.inSeconds == 31 && playing;
        },
      ),
      isTrue,
    );
    newClient.authenticationSessionId = Object();
    expect(recovered.authorized(), isFalse);
    await restarted.clear(token: 'different-queue');
    expect(await restarted.read(), isNotNull);
    await restarted.clear(token: original.token);
    expect(await CastMusicRecovery(MusicLibraryStore(db, 'p'), manager).read(), isNull);
    expect(await CastMusicRecovery(MusicLibraryStore(db, 'other'), manager).read(), isNull);
  });

  test('restart refuses stale, malformed, foreign or unacknowledged queues', () async {
    const connection = (session: 'native-session', device: 'speaker');
    final unacknowledged = await prepare(_snapshot());
    expect(() => unacknowledged.recoveryDocument(connection), throwsStateError);
    final queue = await acknowledgedQueue();
    final now = DateTime.utc(2026, 11, 10);
    final document = queue.recoveryDocument(connection, now: now);
    final status = _status(queue, 1, CastMediaPlayerState.paused);
    CastMusicQueue? recover(Map<String, dynamic> value) =>
        CastMusicQueue.recover(value, manager: manager, connection: connection, status: status, now: now);
    for (final invalid in <Map<String, dynamic>>[
      {...document, 'version': 2},
      {...document, 'session': 'different'},
      {...document, 'device': 'different'},
      {...document, 'mediaSession': 13},
      {...document, 'created': now.add(const Duration(seconds: 1)).millisecondsSinceEpoch},
      {...document, 'created': now.subtract(const Duration(days: 8)).millisecondsSinceEpoch},
      {
        ...document,
        'accounts': {'s': 'other-user'},
      },
      {...document, 'accounts': []},
      {...document, 'snapshot': {}},
      {...document, 'token': 'x' * 129},
    ]) {
      expect(recover(invalid), isNull);
    }
    expect(recover(document), isNotNull);
    client.scopedServerId = 's/other';
    expect(recover(document), isNull);
  });

  test('queue order, duplicate identities and paused cursor are sent independently', () async {
    final snapshot = _snapshot();
    final queue = await prepare(snapshot);
    expect(client.resolved, ['two', 'one']);
    expect(queue.items.map((item) => item.mediaInformation.contentUrl?.path), ['/two.flac', '/one.flac', '/one.flac']);
    expect(queue.items.map((item) => item.autoPlay), [true, false, true]);
    expect(queue.options(snapshot.position).toMap(), containsPair('startIndex', 1));
    expect(queue.options(snapshot.position).toMap(), containsPair('playPosition', 12));
    final duplicate = _status(queue, 2, CastMediaPlayerState.paused, session: 13);
    const connection = (session: 'original', device: 'speaker');
    expect(queue.matches(connection, connection, duplicate), isTrue);
    expect(queue.matches(connection, (session: 'new', device: 'speaker'), duplicate), isFalse);
    expect(queue.acknowledges(duplicate, CastMediaPlayerState.paused), isFalse);
    expect(queue.acknowledges(_status(queue, 1, CastMediaPlayerState.paused), CastMediaPlayerState.paused), isTrue);
  });

  test('account rotation while resolving a stream invalidates the prepared queue', () async {
    final target = Completer<ExternalPlaybackTarget?>();
    client.resolve = (_) => target.future;
    final rejected = expectLater(prepare(_snapshot()), throwsStateError);
    client.authenticationSessionId = Object();
    target.complete(const ExternalPlaybackTarget(url: 'https://server/old.flac'));
    await rejected;
    expect(client.resolved, ['two']);
  });

  test('rejects non-HTTP sources and an oversized encoded request', () async {
    client.resolve = (_) async => const ExternalPlaybackTarget(url: 'file:///download.flac');
    await expectLater(prepare(_snapshot()), throwsStateError);
    client.resolve = (_) async => ExternalPlaybackTarget(url: 'https://server/file.flac?padding=${'a' * 7000}');
    await expectLater(
      prepare(
        MusicTransferSnapshot(
          queue: MusicQueueState(
            items: List.generate(8, (index) => musicTrack('track$index')),
            order: List.generate(8, (index) => index),
            cursor: 0,
            shuffled: false,
            repeatMode: MusicRepeatMode.off,
          ),
          position: Duration.zero,
          playing: false,
        ),
      ),
      throwsStateError,
    );
  });

  for (final android in [true, false]) {
    test('sends the paused queue item through the ${android ? 'Android' : 'iOS'} bridge', () async {
      final queue = await prepare(_snapshot());
      final channel = MethodChannel(
        android ? 'com.felnanuke.google_cast.remote_media_client' : 'google_cast.remote_media_client',
      );
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final pending = Completer<Object?>();
      final received = Completer<MethodCall>();
      messenger.setMockMethodCallHandler(channel, (call) {
        received.complete(call);
        return pending.future;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      var completed = false;
      final dispatch = dispatchCastMusicQueue(
        queue.items,
        queue.options(_snapshot().position),
        android: android,
      ).then((_) => completed = true);
      final call = await received.future;
      expect(call.method, 'queueLoadItems');
      final items = call.arguments[android ? 'queueItems' : 'items'] as List;
      expect(items[1][android ? 'autoPlay' : 'autoplay'], false);
      expect(items[2][android ? 'autoPlay' : 'autoplay'], true);
      expect(items[2]['media']['contentID'], 'pleazyng:test-owner:2');
      expect(call.arguments['options']['startIndex'], 1);
      expect(completed, isFalse);
      pending.complete(true);
      await dispatch;
    });
  }

  for (final revoke in [false, true]) {
    test('handoff ${revoke ? 'rejects a newer local intent' : 'waits for actual receiver playback'}', () async {
      final offer = MusicTransferOffer(_snapshot(), 1, 2, 3, 4);
      final queue = await prepare(offer.snapshot);
      final events = StreamController<GoggleCastMediaStatus?>.broadcast(sync: true);
      addTearDown(events.close);
      final calls = <String>[];
      GoggleCastMediaStatus? status;
      var current = true;
      void publish(CastMediaPlayerState state) {
        status = _status(queue, queue.cursor, state);
        events.add(status);
      }

      final accepted = await queue.handoff(
        offer: offer,
        current: () => current,
        status: () => status,
        statuses: events.stream,
        invalidated: const Stream<void>.empty(),
        load: (items, options) async {
          calls.add('load');
          publish(CastMediaPlayerState.paused);
          if (revoke) current = false;
        },
        play: () async {
          calls.add('play');
          publish(CastMediaPlayerState.playing);
        },
        finish: (offer) async {
          calls.add('pause local');
          return true;
        },
      );
      expect(accepted, !revoke);
      expect(calls, revoke ? ['load'] : ['load', 'play', 'pause local']);
    });
  }

  for (final outcome in ['adopt', 'reject', 'receiver replaced']) {
    test('return uses the current Cast occurrence and handles $outcome', () async {
      final offer = MusicTransferOffer(_snapshot(playing: false), 1, 2, 3, 4);
      final queue = await prepare(offer.snapshot);
      final events = StreamController<GoggleCastMediaStatus?>.broadcast(sync: true);
      addTearDown(events.close);
      GoggleCastMediaStatus? status;
      void publish(int index, CastMediaPlayerState state, {int session = 12}) {
        status = _status(queue, index, state, session: session);
        events.add(status);
      }

      expect(
        await queue.handoff(
          offer: offer,
          current: () => true,
          status: () => status,
          statuses: events.stream,
          invalidated: const Stream.empty(),
          load: (_, _) async => publish(1, CastMediaPlayerState.paused),
          play: () async => fail('the original offer was paused'),
          finish: (_) async => true,
        ),
        isTrue,
      );
      publish(2, CastMediaPlayerState.playing);
      final actions = <String>[];
      final returned = await queue.returnToLocal(
        current: () => true,
        status: () => status,
        statuses: events.stream,
        invalidated: const Stream.empty(),
        position: () => const Duration(seconds: 42),
        pause: () async {
          actions.add('freeze');
          publish(2, CastMediaPlayerState.paused);
        },
        resume: () async => actions.add('resume Cast'),
        prepare: (snapshot, current) async {
          actions.add('prepare');
          expect(snapshot.queue.items, offer.snapshot.queue.items);
          expect(snapshot.queue.order, [1, 2, 0]);
          expect(snapshot.queue.cursor, 2);
          expect(snapshot.queue.shuffled, isTrue);
          return (position, play) async {
            actions.add('adopt');
            expect(current(), isTrue);
            expect(position, const Duration(seconds: 42));
            expect(play, isTrue);
            if (outcome == 'receiver replaced') {
              publish(2, CastMediaPlayerState.paused, session: 13);
              expect(current(), isFalse);
              expect(queue.matchesMedia(status), isFalse);
            }
            return outcome == 'adopt';
          };
        },
      );
      expect(returned, outcome == 'adopt');
      expect(actions, ['prepare', 'freeze', 'adopt', if (outcome == 'reject') 'resume Cast']);
      if (returned) {
        GoggleCastMediaStatus idle(int session, GoogleCastMediaIdleReason reason) => GoggleCastMediaStatus(
          mediaSessionID: session,
          playerState: CastMediaPlayerState.idle,
          idleReason: reason,
          playbackRate: 1,
          volume: 1,
          isMuted: false,
          repeatMode: GoogleCastMediaRepeatMode.off,
        );
        expect(queue.stopAcknowledged(idle(12, GoogleCastMediaIdleReason.cancelled)), isTrue);
        expect(queue.stopAcknowledged(idle(12, GoogleCastMediaIdleReason.finished)), isFalse);
        expect(queue.stopAcknowledged(idle(13, GoogleCastMediaIdleReason.cancelled)), isFalse);
      }
    });
  }
  for (final repeat in [MusicRepeatMode.one, MusicRepeatMode.all]) {
    final nativeRepeat = repeat == MusicRepeatMode.one
        ? GoogleCastMediaRepeatMode.single
        : GoogleCastMediaRepeatMode.all;
    for (final outcome in [
      'acknowledged',
      'unsupported',
      'refused',
      'replaced',
      'revoked',
      'playing',
      'mode changed',
    ]) {
      test('$repeat rearm $outcome keeps sender until exact paused acknowledgement', () async {
        final snapshot = _snapshot(playing: false, repeat: repeat);
        final queue = await prepare(snapshot);
        final events = StreamController<GoggleCastMediaStatus?>.broadcast(sync: true);
        addTearDown(events.close);
        GoggleCastMediaStatus? status;
        var current = true;
        var finished = false;
        var armed = false;
        final accepted = await queue.handoff(
          offer: MusicTransferOffer(snapshot, 1, 2, 3, 4),
          current: () => current,
          status: () => status,
          statuses: events.stream,
          invalidated: const Stream.empty(),
          load: (_, options) async {
            status = _status(queue, queue.cursor, CastMediaPlayerState.paused, repeat: nativeRepeat);
            events.add(status);
          },
          armRepeat: outcome == 'unsupported'
              ? null
              : (loaded) async {
                  armed = true;
                  if (outcome == 'replaced') {
                    status = _status(
                      queue,
                      queue.cursor,
                      CastMediaPlayerState.paused,
                      session: 13,
                      repeat: nativeRepeat,
                    );
                  }
                  if (outcome == 'playing') {
                    status = _status(queue, queue.cursor, CastMediaPlayerState.playing, repeat: nativeRepeat);
                  }
                  if (outcome == 'mode changed') status = _status(queue, queue.cursor, CastMediaPlayerState.paused);
                  if (outcome == 'revoked') current = false;
                  return outcome != 'refused';
                },
          play: () async => fail('paused offer must remain paused'),
          finish: (_) async {
            finished = true;
            return true;
          },
        );
        expect(queue.options(snapshot.position).repeatMode, nativeRepeat);
        expect(
          queue.acknowledges(_status(queue, queue.cursor, CastMediaPlayerState.paused), CastMediaPlayerState.paused),
          isFalse,
          reason: 'receiver must accept repeat mode',
        );
        expect(armed, outcome != 'unsupported');
        expect(accepted, outcome == 'acknowledged');
        expect(finished, outcome == 'acknowledged');
      });
    }

    test('$repeat rearmed item can play and recover without persisting streams', () async {
      final snapshot = _snapshot(repeat: repeat);
      final queue = await prepare(snapshot);
      final events = StreamController<GoggleCastMediaStatus?>.broadcast(sync: true);
      addTearDown(events.close);
      GoggleCastMediaStatus? status;
      final actions = <String>[];
      void publish(CastMediaPlayerState state) {
        status = _status(queue, queue.cursor, state, repeat: nativeRepeat);
        events.add(status);
      }

      expect(
        await queue.handoff(
          offer: MusicTransferOffer(snapshot, 1, 2, 3, 4),
          current: () => true,
          status: () => status,
          statuses: events.stream,
          invalidated: const Stream.empty(),
          load: (_, _) async {
            actions.add('load');
            publish(CastMediaPlayerState.paused);
          },
          armRepeat: (_) async {
            actions.add('arm');
            return true;
          },
          play: () async {
            actions.add('play');
            publish(CastMediaPlayerState.playing);
          },
          finish: (_) async {
            actions.add('finish');
            return true;
          },
        ),
        isTrue,
      );
      expect(actions, ['load', 'arm', 'play', 'finish']);
      const connection = (session: 'session', device: 'speaker');
      final document = queue.recoveryDocument(connection);
      expect(jsonEncode(document), isNot(contains('https://')));
      final recovered = CastMusicQueue.recover(document, manager: manager, connection: connection, status: status)!;
      expect(recovered.options(Duration.zero).repeatMode, nativeRepeat);
      expect(recovered.isFinalOccurrence(_status(queue, 2, CastMediaPlayerState.idle, repeat: nativeRepeat)), isFalse);
      expect(recovered.isFinalOccurrence(_status(queue, 2, CastMediaPlayerState.idle)), isTrue);
    });
  }

  for (final repeat in GoogleCastMediaRepeatMode.values) {
    test('return preserves receiver repeat $repeat or refuses an unrepresentable mode', () async {
      final queue = await acknowledgedQueue();
      final events = StreamController<GoggleCastMediaStatus?>.broadcast(sync: true);
      addTearDown(events.close);
      GoggleCastMediaStatus status = _status(queue, 2, CastMediaPlayerState.playing, repeat: repeat);
      MusicRepeatMode? returnedRepeat;
      var prepared = false;
      var paused = false;
      final accepted = await queue.returnToLocal(
        current: () => true,
        status: () => status,
        statuses: events.stream,
        invalidated: const Stream.empty(),
        position: () => const Duration(seconds: 8),
        pause: () async {
          paused = true;
          status = _status(queue, 2, CastMediaPlayerState.paused, repeat: repeat);
          events.add(status);
        },
        resume: () async => fail('accepted or refused before pause'),
        prepare: (snapshot, current) async {
          prepared = true;
          returnedRepeat = snapshot.queue.repeatMode;
          return (_, _) async => current();
        },
      );
      final expected = switch (repeat) {
        GoogleCastMediaRepeatMode.off => MusicRepeatMode.off,
        GoogleCastMediaRepeatMode.single => MusicRepeatMode.one,
        GoogleCastMediaRepeatMode.all => MusicRepeatMode.all,
        _ => null,
      };
      expect(accepted, expected != null);
      expect(prepared, expected != null);
      expect(paused, expected != null);
      expect(returnedRepeat, expected);
    });
  }

  test('repeat edit during local preflight cancels return before pausing receiver', () async {
    final queue = await acknowledgedQueue();
    GoggleCastMediaStatus status = _status(queue, 2, CastMediaPlayerState.playing);
    final events = StreamController<GoggleCastMediaStatus?>.broadcast(sync: true);
    addTearDown(events.close);
    expect(
      await queue.returnToLocal(
        current: () => true,
        status: () => status,
        statuses: events.stream,
        invalidated: const Stream.empty(),
        position: () => Duration.zero,
        pause: () async => fail('mode changed'),
        resume: () async => fail('never frozen'),
        prepare: (_, current) async {
          status = _status(queue, 2, CastMediaPlayerState.playing, repeat: GoogleCastMediaRepeatMode.single);
          return (_, _) async => current();
        },
      ),
      isFalse,
    );
  });

  test('native rearm bridge waits for SDK acknowledgement and passes only ownership fields', () async {
    final queue = await prepare(_snapshot(repeat: MusicRepeatMode.all));
    const channel = MethodChannel('com.pleazyng/cast_music_queue');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final pending = Completer<Object?>();
    final received = Completer<MethodCall>();
    messenger.setMockMethodCallHandler(channel, (call) {
      received.complete(call);
      return pending.future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    var complete = false;
    final result = queue
        .armRepeat((
          session: 'session',
          device: 'speaker',
        ), _status(queue, 1, CastMediaPlayerState.paused, repeat: GoogleCastMediaRepeatMode.all))
        .then((accepted) {
          complete = true;
          return accepted;
        });
    final call = await received.future;
    expect(call.method, 'armRepeat');
    expect(call.arguments, {
      'session': 'session',
      'device': 'speaker',
      'mediaSession': 12,
      'item': 2,
      'token': 'test-owner',
      'occurrence': '1',
      'contentId': 'pleazyng:test-owner:1',
      'repeat': 'ALL',
    });
    expect(jsonEncode(call.arguments), isNot(contains('https://')));
    expect(complete, isFalse);
    pending.complete(true);
    expect(await result, isTrue);
    expect(
      await queue.armRepeat((
        session: 'session',
        device: 'speaker',
      ), _status(queue, 1, CastMediaPlayerState.playing, repeat: GoogleCastMediaRepeatMode.all)),
      isFalse,
    );
  });

  test('same authentication with changed music account invalidates queue resolution', () async {
    final target = Completer<ExternalPlaybackTarget?>();
    client.resolve = (_) => target.future;
    final rejected = expectLater(prepare(_snapshot()), throwsStateError);
    client.scopedServerId = 's/other-user';
    target.complete(const ExternalPlaybackTarget(url: 'https://server/old.flac'));
    await rejected;
  });
}
