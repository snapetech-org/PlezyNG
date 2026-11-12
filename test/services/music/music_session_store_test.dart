import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/music/music_queue_controller.dart';
import 'package:plezy/services/music/music_queue_items.dart';
import 'package:plezy/services/music/music_session_store.dart';
import '../../test_helpers/media_items.dart';

void main() {
  late AppDatabase db;
  late Directory scratch;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final parent = Directory('.dart_tool/queue-spool-tests')..createSync(recursive: true);
    scratch = parent.createTempSync('restore-');
  });

  tearDown(() async {
    await db.close();
    scratch.deleteSync(recursive: true);
  });

  MusicSessionStore store({String profileId = 'p1'}) =>
      MusicSessionStore(database: db, profileId: profileId, queueScratchDirectory: scratch);

  MediaItem track(String id) =>
      testMediaItem(id: id, kind: MediaKind.track, title: 'Track $id', serverId: 'srv', durationMs: 180000);

  MusicQueueState state({
    required List<MediaItem> items,
    List<int>? order,
    int cursor = 0,
    bool shuffled = false,
    MusicRepeatMode repeatMode = MusicRepeatMode.off,
  }) => MusicQueueState(
    items: items,
    order: order ?? [for (var i = 0; i < items.length; i++) i],
    cursor: cursor,
    shuffled: shuffled,
    repeatMode: repeatMode,
  );

  Future<void> auditWrites() async {
    await db.customStatement('CREATE TABLE queue_write_audit (operation TEXT NOT NULL)');
    for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
      await db.customStatement(
        'CREATE TRIGGER queue_audit_${operation.toLowerCase()} AFTER $operation ON music_queue_entries BEGIN '
        "INSERT INTO queue_write_audit VALUES ('$operation'); END",
      );
    }
  }

  Future<Map<String, int>> written() async => {
    for (final row
        in await db.customSelect('SELECT operation, COUNT(*) AS n FROM queue_write_audit GROUP BY operation').get())
      row.read<String>('operation'): row.read<int>('n'),
  };

  test('mode edits write no queue rows and append writes only the new occurrence', () async {
    final session = store();
    final items = [for (var i = 0; i < 100; i++) track('track-$i')];
    MusicSessionSnapshot snapshot(List<MediaItem> items, MusicRepeatMode mode) => MusicSessionSnapshot(
      queue: state(items: items, repeatMode: mode),
      playContext: null,
      position: Duration.zero,
    );
    await session.save(snapshot(items, MusicRepeatMode.off));
    await auditWrites();
    await session.save(snapshot(items, MusicRepeatMode.all));
    expect(await written(), isEmpty);
    await session.save(snapshot([...items, track('tail')], MusicRepeatMode.all));
    expect(await written(), {'INSERT': 1});
    final loaded = await session.load();
    expect(loaded!.queue.items.last.id, 'tail');
    expect(loaded.queue.repeatMode, MusicRepeatMode.all);
  });

  test('cyclic reordering changes only moved positions and preserves duplicate occurrences', () async {
    final session = store();
    final items = [track('a'), track('a'), track('b'), track('c')];
    MusicSessionSnapshot snapshot(List<int> order) => MusicSessionSnapshot(
      queue: state(items: items, order: order, shuffled: true),
      playContext: null,
      position: Duration.zero,
    );
    await session.save(snapshot([0, 1, 2, 3]));
    await auditWrites();
    await session.save(snapshot([1, 2, 0, 3]));
    expect(await written(), {'UPDATE': 6});
    final loaded = await session.load();
    expect(loaded!.queue.order, [1, 2, 0, 3]);
    expect(loaded.queue.items.map((item) => item.id), ['a', 'a', 'b', 'c']);
    await db.customStatement('DELETE FROM queue_write_audit');
    await session.save(snapshot([1, 2, 0, 3]));
    expect(await written(), isEmpty);
  });

  test('shrinking a queue deletes only its retired canonical tail', () async {
    final session = store();
    final items = [for (var i = 0; i < 10; i++) track('track-$i')];
    MusicSessionSnapshot snapshot(List<MediaItem> items) => MusicSessionSnapshot(
      queue: state(items: items),
      playContext: null,
      position: Duration.zero,
    );
    await session.save(snapshot(items));
    await auditWrites();
    await session.save(snapshot(items.take(7).toList()));
    expect(await written(), {'DELETE': 3});
    expect((await session.load())!.queue.items.map((item) => item.id), items.take(7).map((item) => item.id));
  });

  test('failure after staging a permutation rolls back entries and the session header', () async {
    final session = store();
    final items = [track('a'), track('b'), track('c')];
    final before = MusicSessionSnapshot(
      queue: state(items: items),
      playContext: null,
      position: const Duration(seconds: 12),
    );
    await session.save(before);
    await db.customStatement(
      'CREATE TRIGGER reject_queue_commit BEFORE UPDATE ON music_queue_entries '
      'WHEN NEW.canonical_index = 2 AND NEW.playback_index >= 0 '
      "BEGIN SELECT RAISE(ABORT, 'test queue write refusal'); END",
    );
    await expectLater(
      session.save(
        MusicSessionSnapshot(
          queue: state(items: items, order: [2, 0, 1], shuffled: true),
          playContext: const MusicPlayContext(title: 'New context', kind: MusicPlayContextKind.mix),
          position: const Duration(seconds: 99),
        ),
      ),
      throwsA(isA<Exception>()),
    );
    final loaded = await session.load();
    expect(loaded!.queue.order, [0, 1, 2]);
    expect(loaded.queue.shuffled, isFalse);
    expect(loaded.position, before.position);
    expect(loaded.playContext, isNull);
    await db.customStatement('DROP TRIGGER reject_queue_commit');
    await session.save(before);
    expect((await session.load())!.queue.order, [0, 1, 2]);
  });

  test('a malformed old queue is replaced atomically on the next valid save', () async {
    final session = store();
    final snapshot = MusicSessionSnapshot(
      queue: state(items: [track('a'), track('b')]),
      playContext: null,
      position: Duration.zero,
    );
    await session.save(snapshot);
    await db.customStatement('UPDATE music_queue_entries SET playback_index = -1 WHERE canonical_index = 0');
    expect(await session.load(), isNull);
    await session.save(snapshot);
    expect((await session.load())!.queue.order, [0, 1]);
  });

  test('a retired store cannot resurrect or clear a replacement profile session', () async {
    final retired = store();
    final snapshot = MusicSessionSnapshot(
      queue: state(items: [track('a')]),
      playContext: null,
      position: Duration.zero,
    );
    final pending = retired.save(snapshot);
    await db.deleteMusicRecipesForProfile('p1');
    await db.deleteMusicSessionForProfile('p1');
    await pending;
    expect(await retired.load(), isNull);
    final replacement = store();
    expect(await replacement.load(), isNull);
    await replacement.save(snapshot);
    await retired.clear();
    await retired.save(snapshot);
    await retired.updateProgress(cursor: 0, position: const Duration(seconds: 33));
    expect((await replacement.load())!.position, Duration.zero);
  });

  test('mixed edits round-trip full occurrence order through incremental saves', () async {
    final session = store();
    final queue = MusicQueueController(random: Random(17));
    queue.load([for (var i = 0; i < 8; i++) track('track-${i % 3}')], startIndex: 3);
    final random = Random(41);
    for (var step = 0; step < 48; step++) {
      switch (step % 4) {
        case 0:
          queue.addNext([track('added-$step')]);
        case 1:
          if (queue.length > 1) queue.removeAt(random.nextInt(queue.length));
        case 2:
          queue.move(random.nextInt(queue.length), random.nextInt(queue.length));
        case 3:
          queue.toggleShuffle();
      }
      final expected = queue.captureState();
      await session.save(MusicSessionSnapshot(queue: expected, playContext: null, position: Duration.zero));
      final restored = (await session.load())!.queue;
      expect(restored.items.map((item) => item.id), expected.items.map((item) => item.id), reason: 'step $step');
      expect(restored.order, expected.order, reason: 'step $step');
      expect(restored.cursor, expected.cursor, reason: 'step $step');
      expect(restored.shuffled, expected.shuffled, reason: 'step $step');
    }
  });

  test('round-trips queue state, provenance, and position', () async {
    final items = [track('a'), track('b'), track('c')];
    await store().save(
      MusicSessionSnapshot(
        queue: state(items: items, order: [2, 0, 1], cursor: 1, shuffled: true, repeatMode: MusicRepeatMode.all),
        playContext: const MusicPlayContext(title: 'Mixtape', kind: MusicPlayContextKind.playlist),
        position: const Duration(seconds: 93),
      ),
    );

    final loaded = await store().load();

    expect(loaded, isNotNull);
    expect([for (final t in loaded!.queue.items) t.id], ['a', 'b', 'c']);
    expect(loaded.queue.order, [2, 0, 1]);
    expect(loaded.queue.cursor, 1);
    expect(loaded.queue.shuffled, isTrue);
    expect(loaded.queue.repeatMode, MusicRepeatMode.all);
    expect(loaded.playContext?.title, 'Mixtape');
    expect(loaded.playContext?.kind, MusicPlayContextKind.playlist);
    expect(loaded.position, const Duration(seconds: 93));
    // The tracks must stay playable after the round trip.
    expect(loaded.queue.items.first.serverId, 'srv');
    expect(loaded.queue.items.first.durationMs, 180000);
  });

  test('a loaded shuffled state un-shuffles back to canonical order through the controller', () async {
    final items = [track('a'), track('b'), track('c')];
    await store().save(
      MusicSessionSnapshot(
        queue: state(items: items, order: [2, 0, 1], cursor: 0, shuffled: true),
        playContext: null,
        position: Duration.zero,
      ),
    );

    final loaded = await store().load();
    final controller = MusicQueueController();
    expect(controller.restoreState(loaded!.queue), isTrue);
    expect([for (final t in controller.queue) t.id], ['c', 'a', 'b']);

    controller.toggleShuffle();
    expect([for (final t in controller.queue) t.id], ['a', 'b', 'c']);
    expect(controller.current!.id, 'c');
  });

  test('updateProgress rewrites cursor and position without touching the queue', () async {
    final items = [track('a'), track('b')];
    await store().save(
      MusicSessionSnapshot(
        queue: state(items: items),
        playContext: null,
        position: Duration.zero,
      ),
    );

    await store().updateProgress(cursor: 1, position: const Duration(seconds: 30));

    final loaded = await store().load();
    expect(loaded!.queue.cursor, 1);
    expect(loaded.position, const Duration(seconds: 30));
    expect([for (final t in loaded.queue.items) t.id], ['a', 'b']);
  });

  test('updateProgress without a snapshot row is a no-op', () async {
    await store().updateProgress(cursor: 3, position: const Duration(seconds: 5));
    expect(await store().load(), isNull);
  });

  test('clear removes the row', () async {
    await store().save(
      MusicSessionSnapshot(
        queue: state(items: [track('a')]),
        playContext: null,
        position: Duration.zero,
      ),
    );
    await store().clear();
    expect(await store().load(), isNull);
  });

  test('profiles are isolated', () async {
    await store().save(
      MusicSessionSnapshot(
        queue: state(items: [track('a')]),
        playContext: null,
        position: Duration.zero,
      ),
    );
    expect(await store(profileId: 'p2').load(), isNull);
    expect(await store().load(), isNotNull);
  });

  test('continuation seed, account and exclusions survive restart within their profile', () async {
    await store().save(
      MusicSessionSnapshot(
        queue: state(items: [track('a')]),
        playContext: null,
        position: Duration.zero,
        continuationSeed: track('seed'),
        continuationAccount: 'srv:account',
        continuationExcluded: {'srv:removed'},
      ),
    );
    final restored = await store().load();
    expect(restored!.continuationSeed!.id, 'seed');
    expect(restored.continuationSeed!.serverId, 'srv');
    expect(restored.continuationAccount, 'srv:account');
    expect(restored.continuationExcluded, {'srv:removed'});
    expect(await store(profileId: 'other').load(), isNull);
  });

  test('album radio mode and distance survive a parked session', () async {
    final seed = track('album').copyWith(kind: MediaKind.album);
    await store().save(
      MusicSessionSnapshot(
        queue: state(items: [track('a')]),
        playContext: null,
        position: Duration.zero,
        continuationSeed: seed,
        continuationAccount: 'srv:account',
        continuationAlbumRadio: true,
        continuationDistance: .4,
      ),
    );
    final restored = (await store().load())!;
    expect(restored.continuationAlbumRadio, isTrue);
    expect(restored.continuationDistance, .4);
    expect(restored.continuationSeed!.kind, MediaKind.album);
  });

  test('track continuation retains legacy defaults', () async {
    await store().save(
      MusicSessionSnapshot(
        queue: state(items: [track('a')]),
        playContext: null,
        position: Duration.zero,
        continuationSeed: track('seed'),
        continuationAccount: 'srv:account',
      ),
    );
    final row = (await db.getMusicSession('p1'))!;
    final payload = jsonDecode(row.queueJson) as Map<String, dynamic>;
    final continuation = payload['continuation'] as Map<String, dynamic>;
    continuation.remove('albumRadio');
    continuation.remove('distance');
    await db.upsertMusicSession(row.copyWith(queueJson: jsonEncode(payload)));
    final restored = (await store().load())!;
    expect(restored.continuationAlbumRadio, isFalse);
    expect(restored.continuationDistance, .25);
  });

  test('invalid album continuation cannot replace a saved queue', () async {
    await store().save(
      MusicSessionSnapshot(
        queue: state(items: [track('a')]),
        playContext: null,
        position: Duration.zero,
      ),
    );
    await expectLater(
      store().save(
        MusicSessionSnapshot(
          queue: state(items: [track('b')]),
          playContext: null,
          position: Duration.zero,
          continuationSeed: track('not-an-album'),
          continuationAlbumRadio: true,
        ),
      ),
      throwsArgumentError,
    );
    expect((await store().load())!.queue.items.single.id, 'a');
  });

  test('malformed queue JSON discards the whole snapshot', () async {
    await db.upsertMusicSession(
      MusicSessionRow(
        profileId: 'p1',
        queueJson: 'not json',
        orderJson: '[0]',
        cursor: 0,
        shuffled: false,
        repeatMode: 'off',
        contextTitle: null,
        contextKind: null,
        positionMs: 0,
        updatedAt: 0,
      ),
    );
    expect(await store().load(), isNull);
  });

  test('legacy JSON queues upgrade without losing duplicate occurrences', () async {
    await db.upsertMusicSession(
      MusicSessionRow(
        profileId: 'p1',
        queueJson: jsonEncode([track('a').toJson(), track('a').toJson(), track('b').toJson()]),
        orderJson: '[2,0,1]',
        cursor: 1,
        shuffled: true,
        repeatMode: 'off',
        contextTitle: 'Old queue',
        contextKind: 'tracks',
        positionMs: 12000,
        updatedAt: 0,
      ),
    );
    final snapshot = await store().load();
    expect(snapshot!.queue.order, [2, 0, 1]);
    expect(snapshot.queue.items.map((t) => t.id), ['a', 'a', 'b']);
    await store().save(snapshot);
    final row = await db.getMusicSession('p1');
    expect(jsonDecode(row!.queueJson), {'version': 2, 'length': 3});
    expect((await store().load())!.position, const Duration(seconds: 12));
  });

  test('invalid legacy permutations are rejected at the persistence boundary', () async {
    await db.upsertMusicSession(
      MusicSessionRow(
        profileId: 'p1',
        queueJson: jsonEncode([track('a').toJson(), track('b').toJson()]),
        orderJson: '[0,0]',
        cursor: 0,
        shuffled: true,
        repeatMode: 'off',
        contextTitle: null,
        contextKind: null,
        positionMs: 0,
        updatedAt: 0,
      ),
    );
    expect(await store().load(), isNull);
  });

  test('an unknown repeat-mode id discards the snapshot', () async {
    await db.upsertMusicSession(
      MusicSessionRow(
        profileId: 'p1',
        queueJson: '[]',
        orderJson: '[]',
        cursor: 0,
        shuffled: false,
        repeatMode: 'bogus',
        contextTitle: null,
        contextKind: null,
        positionMs: 0,
        updatedAt: 0,
      ),
    );
    expect(await store().load(), isNull);
  });

  test('10,000 tracks and duplicate occurrences retain full canonical and shuffle order', () async {
    final items = [for (var i = 0; i < 10000; i++) track('i${i ~/ 2}')];
    final order = [for (var i = items.length - 1; i >= 0; i--) i];
    final session = store();
    await session.save(
      MusicSessionSnapshot(
        queue: state(items: items, order: order, cursor: 700, shuffled: true),
        playContext: null,
        position: const Duration(seconds: 35),
      ),
    );
    final loaded = await session.load();
    expect(loaded!.queue.items, isA<MusicQueueItemsSnapshot>());
    expect(loaded.queue.items, hasLength(10000));
    expect(scratch.listSync(), hasLength(1));
    expect(loaded.queue.order, order);
    expect(loaded.queue.cursor, 700);
    final controller = MusicQueueController();
    expect(controller.restoreState(loaded.queue), isTrue);
    final current = controller.current!.id;
    controller.toggleShuffle();
    expect(controller.queue.map((t) => t.id), items.map((t) => t.id));
    expect(controller.current!.id, current);
    await session.updateProgress(cursor: 9999, position: const Duration(seconds: 1));
    expect((await session.load())!.queue.cursor, 9999);
  });

  test('save, progress and clear serialize without resurrecting a stopped session', () async {
    final session = store();
    final save = session.save(
      MusicSessionSnapshot(
        queue: state(items: [track('a'), track('b')]),
        playContext: null,
        position: Duration.zero,
      ),
    );
    final progress = session.updateProgress(cursor: 1, position: const Duration(seconds: 30));
    final clear = session.clear();
    await Future.wait([save, progress, clear]);
    expect(await session.load(), isNull);
    final count = await db.customSelect('SELECT COUNT(*) AS n FROM music_queue_entries').getSingle();
    expect(count.read<int>('n'), 0);
  });

  test('partial durable queue is rejected instead of silently truncating', () async {
    final session = store();
    await session.save(
      MusicSessionSnapshot(
        queue: state(items: [track('a'), track('b')]),
        playContext: null,
        position: Duration.zero,
      ),
    );
    await db.customStatement('DELETE FROM music_queue_entries WHERE canonical_index = 1');
    expect(await session.load(), isNull);
  });
}
