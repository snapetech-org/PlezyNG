import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/music/music_group_exchange.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/music/music_queue_controller.dart';
import 'package:plezy/services/music/music_transfer_snapshot.dart';

MusicTransferSnapshot _snapshot({bool playing = true, int position = 12000, int cursor = 0, bool shuffle = false}) =>
    MusicTransferSnapshot(
      queue: MusicQueueState(
        items: [
          MediaItem(id: '7', backend: MediaBackend.plex, kind: MediaKind.track, serverId: 'server'),
          MediaItem(id: '7', backend: MediaBackend.plex, kind: MediaKind.track, serverId: 'server'),
        ],
        order: const [0, 1],
        cursor: cursor,
        shuffled: shuffle,
        repeatMode: MusicRepeatMode.off,
      ),
      position: Duration(milliseconds: position),
      playing: playing,
    );

void main() {
  test('clock offset uses a bounded round trip and keeps the best sample', () {
    final clock = MusicGroupClock();
    expect(clock.ready, isFalse);
    expect(clock.observe(100, 1110, 1110, 120), isTrue);
    expect(clock.offset, 1000);
    expect(clock.observe(200, 1300, 1300, 400), isTrue);
    expect(clock.offset, 1000);
    expect(clock.observe(300, 3000, 3000, 2000), isFalse);
    expect(clock.observe(300, 1200, 1100, 400), isFalse);
    expect(clock.observe(300, 1300, 1400, 350), isFalse);
  });

  test('prepares paused, corrects distinct clock epochs and follows play/pause and duplicate cursor', () {
    fakeAsync((async) {
      final pair = _Pair(async);
      bool? joined;
      unawaited(pair.leader.start().then((value) => joined = value));
      async.flushMicrotasks();
      expect(joined, isTrue);
      expect(pair.prepared.single.playing, isFalse);
      expect(pair.aligned.single.position, const Duration(seconds: 12));
      expect(pair.aligned.single.playing, isTrue);
      pair.snapshot = _snapshot(playing: false, position: 9000, cursor: 1);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(pair.aligned.last.playing, isFalse);
      expect(pair.aligned.last.position, const Duration(seconds: 9));
      expect(pair.aligned.last.queue.cursor, 1);
      expect(pair.leader.joined, isTrue);
      pair.close();
    });
  });

  test('rejects stale anchors, unknown fields and wrong group identifiers', () {
    fakeAsync((async) {
      final pair = _Pair(async);
      unawaited(pair.leader.start());
      async.flushMicrotasks();
      final anchor = pair.messages.lastWhere((message) => message['op'] == 'anchor');
      final count = pair.aligned.length;
      pair.follower.receive(anchor);
      pair.follower.receive({...anchor, 'sequence': 100, 'token': 'secret'});
      pair.follower.receive({...anchor, 'sequence': 100, 'group': 'b' * 32});
      pair.follower.receive({...anchor, 'sequence': 100, 'sent': 0});
      async.flushMicrotasks();
      expect(pair.aligned.length, count);
      pair.close();
    });
  });

  test('queue replacement ends rather than silently diverging the group', () {
    fakeAsync((async) {
      final pair = _Pair(async);
      unawaited(pair.leader.start());
      async.flushMicrotasks();
      pair.snapshot = _snapshot(shuffle: true);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(pair.leader.active, isFalse);
      expect(pair.follower.active, isFalse);
      expect(pair.releases, 2);
      pair.close();
    });
  });

  test('missing heartbeats retires both sides without rejoining stale messages', () {
    fakeAsync((async) {
      final pair = _Pair(async);
      unawaited(pair.leader.start());
      async.flushMicrotasks();
      pair.deliver = false;
      async.elapse(const Duration(seconds: 7));
      async.flushMicrotasks();
      expect(pair.leader.active, isFalse);
      expect(pair.follower.active, isFalse);
      pair.deliver = true;
      pair.follower.receive(pair.messages.lastWhere((message) => message['op'] == 'anchor'));
      expect(pair.follower.active, isFalse);
      pair.close();
    });
  });

  test('lost authority and denied alignment stop the group', () {
    fakeAsync((async) {
      final pair = _Pair(async);
      unawaited(pair.leader.start());
      async.flushMicrotasks();
      pair.acceptAlignment = false;
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(pair.leader.active, isFalse);
      expect(pair.follower.active, isFalse);
      pair.allowed = false;
      bool? started;
      unawaited(pair.leader.start().then((value) => started = value));
      async.flushMicrotasks();
      expect(started, isFalse);
      pair.close();
    });
  });

  test('expired preparation cannot resurrect playback', () {
    fakeAsync((async) {
      final gate = Completer<bool>();
      final pair = _Pair(async, gate: gate);
      bool? joined;
      unawaited(pair.leader.start().then((value) => joined = value));
      async.flushMicrotasks();
      expect(pair.preparationCurrent!(), isTrue);
      async.elapse(const Duration(seconds: 21));
      async.flushMicrotasks();
      expect(joined, isFalse);
      expect(pair.preparationCurrent!(), isFalse);
      gate.complete(true);
      async.flushMicrotasks();
      expect(pair.aligned, isEmpty);
      pair.close();
    });
  });
}

class _Pair {
  _Pair(FakeAsync async, {Completer<bool>? gate}) {
    leader = MusicGroupExchange(
      allowed: () => allowed,
      capture: () => snapshot,
      prepare: (_, _) async => false,
      align: (_, _) async => false,
      release: () async {
        releases++;
      },
      changed: () {},
      now: () => 10000 + async.elapsed.inMilliseconds,
      send: (message) {
        messages.add(message);
        if (deliver) follower.receive(message);
      },
    );
    follower = MusicGroupExchange(
      allowed: () => allowed,
      capture: () => null,
      prepare: (snapshot, current) {
        prepared.add(snapshot);
        preparationCurrent = current;
        return gate?.future ?? Future.value(true);
      },
      align: (snapshot, current) async {
        aligned.add(snapshot);
        return acceptAlignment && current();
      },
      release: () async {
        releases++;
      },
      changed: () {},
      now: () => 2000 + async.elapsed.inMilliseconds,
      send: (message) {
        if (deliver) leader.receive(message);
      },
    );
  }
  late final MusicGroupExchange leader, follower;
  bool allowed = true, deliver = true, acceptAlignment = true;
  int releases = 0;
  bool Function()? preparationCurrent;
  MusicTransferSnapshot snapshot = _snapshot();
  final messages = <Map<String, dynamic>>[];
  final prepared = <MusicTransferSnapshot>[];
  final aligned = <MusicTransferSnapshot>[];
  void close() {
    leader.close();
    follower.close();
  }
}
