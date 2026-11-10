import 'dart:async';

import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/music/cast_music_queue.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/music/music_queue_controller.dart';
import 'package:plezy/services/music/music_transfer_snapshot.dart';
import 'package:plezy/services/playback_initialization_service.dart';

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

GoggleCastMediaStatus _status(CastMusicQueue queue, int index, CastMediaPlayerState state, {int session = 12}) =>
    GoggleCastMediaStatus(
      mediaSessionID: session,
      playerState: state,
      playbackRate: 1,
      volume: 1,
      isMuted: false,
      repeatMode: GoogleCastMediaRepeatMode.off,
      currentItemId: index + 1,
      mediaInformation: queue.items[index].mediaInformation,
    );

void main() {
  late _Client client;
  late MultiServerManager manager;

  setUp(() {
    client = _Client();
    manager = MultiServerManager()..debugRegisterClientForTesting(client);
    addTearDown(manager.dispose);
  });

  Future<CastMusicQueue> prepare(MusicTransferSnapshot snapshot) =>
      CastMusicQueue.prepare(snapshot, manager: manager, token: 'test-owner', current: () => true);

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

  test('rejects repeats, non-HTTP sources and an oversized encoded request', () async {
    await expectLater(prepare(_snapshot(repeat: MusicRepeatMode.all)), throwsStateError);
    expect(client.resolved, isEmpty);
    client.resolve = (_) async => const ExternalPlaybackTarget(url: 'file:///download.flac');
    await expectLater(prepare(_snapshot()), throwsStateError);
    client.resolve = (_) async => ExternalPlaybackTarget(url: 'https://server/file.flac?padding=${'a' * 7000}');
    await expectLater(
      prepare(
        MusicTransferSnapshot(
          queue: MusicQueueState(
            items: List.generate(4, (index) => musicTrack('track$index')),
            order: [0, 1, 2, 3],
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
}
