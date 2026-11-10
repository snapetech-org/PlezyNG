import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/music/music_queue_controller.dart';
import 'package:plezy/services/music/music_session_store.dart';
import '../../test_helpers/media_items.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  MusicSessionStore store({String profileId = 'p1'}) => MusicSessionStore(database: db, profileId: profileId);

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
    expect(loaded!.queue.items, hasLength(10000));
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
