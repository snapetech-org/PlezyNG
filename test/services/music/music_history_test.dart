import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/music/music_library_store.dart';
import 'package:plezy/services/music/music_listening_recorder.dart';
import '../../test_helpers/music_experience_fakes.dart';

void main() {
  late AppDatabase db;
  late MusicLibraryStore store;
  final now = DateTime.utc(2026, 11, 9);
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = MusicLibraryStore(db, 'virtual-profile');
  });
  tearDown(() async => db.close());
  Future<List<MusicChartEntry>> chart({MusicChartGroup group = MusicChartGroup.tracks}) =>
      store.chart(from: now.subtract(const Duration(days: 365)), until: now.add(const Duration(days: 1)), group: group);

  test('cursor pages retain repeated occurrences and timestamp ties without duplicates', () async {
    for (var index = 0; index < 123; index++) {
      await store.record(
        id: index.toString().padLeft(3, '0'),
        track: musicTrack('same'),
        startedAt: now,
        listenedMs: 30000,
        finished: true,
      );
    }
    final first = await store.historyPage();
    expect(first.entries, hasLength(50));
    await store.record(
      id: 'newer',
      track: musicTrack('newer'),
      startedAt: now.add(const Duration(seconds: 1)),
      listenedMs: 30000,
      finished: true,
    );
    final second = await store.historyPage(before: first.cursor);
    final third = await store.historyPage(before: second.cursor);
    final entries = [...first.entries, ...second.entries, ...third.entries];
    expect(entries.map((entry) => entry.id).toSet(), hasLength(123));
    expect(entries.first.id, '122');
    expect(entries.last.id, '000');
    expect(third.cursor, isNull);
    expect((await store.historyPage()).entries.first.id, 'newer');
    expect(await MusicLibraryStore(db, 'other').historyPage().then((page) => page.entries), isEmpty);
  });

  test('history observes committed writes and clearing across store instances', () async {
    final other = MusicLibraryStore(db, store.profileId);
    final change = other.historyChanges.first;
    await store.record(id: 'one', track: musicTrack('song'), startedAt: now, listenedMs: 30000, finished: true);
    await change;
    expect((await other.historyPage()).entries.single.listenedMs, 30000);
    final cleared = other.historyChanges.first;
    await store.clearHistory();
    await cleared;
    expect((await other.historyPage()).entries, isEmpty);
    await expectLater(store.historyPage(limit: 101), throwsArgumentError);
    await db.deleteMusicRecipesForProfile(store.profileId);
    expect((await store.historyPage()).entries, isEmpty);
  });

  test('cumulative retry and out of order writes count one qualified occurrence', () async {
    for (final amount in [15000, 30000, 30000, 20000]) {
      await store.record(id: 'one', track: musicTrack('song'), startedAt: now, listenedMs: amount, finished: false);
    }
    final row = (await chart()).single;
    expect(row.plays, 1);
    expect(row.listenedMs, 30000);
    await store.record(id: 'two', track: musicTrack('song'), startedAt: now, listenedMs: 60000, finished: true);
    expect((await chart()).single.plays, 2);
  });
  test('short skip does not qualify, long or unknown streams require four minutes', () async {
    await store.record(id: 'skip', track: musicTrack('skip'), startedAt: now, listenedMs: 29999, finished: true);
    await store.record(
      id: 'long',
      track: musicTrack('long', durationMs: 3600000),
      startedAt: now,
      listenedMs: 240000,
      finished: false,
    );
    await store.record(
      id: 'unknown',
      track: musicTrack('stream', durationMs: null),
      startedAt: now,
      listenedMs: 239999,
      finished: false,
    );
    expect((await chart()).map((c) => c.item.id), ['long']);
  });
  test('profile and server qualified charts keep identities separate', () async {
    for (final server in ['s', 'other']) {
      await store.record(
        id: server,
        track: musicTrack('same', server: server),
        startedAt: now,
        listenedMs: 30000,
        finished: true,
      );
    }
    expect(await chart(group: MusicChartGroup.albums), hasLength(2));
    expect(await chart(group: MusicChartGroup.artists), hasLength(2));
    expect(await MusicLibraryStore(db, 'other-profile').recent(), isEmpty);
  });
  test('history strips raw payloads and credentials', () async {
    final item = musicTrack('song').copyWith(raw: {'token': 'secret'}, thumbPath: 'https://host/image?token=secret');
    await store.record(id: 'one', track: item, startedAt: now, listenedMs: 30000, finished: true);
    final data = jsonEncode((await store.recent()).single.toJson());
    expect(data, isNot(contains('secret')));
  });
  test('rediscovery excludes a track played again recently', () async {
    await store.record(
      id: 'old',
      track: musicTrack('song'),
      startedAt: now.subtract(const Duration(days: 100)),
      listenedMs: 30000,
      finished: true,
    );
    expect(await store.recent(rediscover: true, now: now), hasLength(1));
    await store.record(id: 'new', track: musicTrack('song'), startedAt: now, listenedMs: 30000, finished: true);
    expect(await store.recent(rediscover: true, now: now), isEmpty);
  });
  test('permanent teardown invalidates old stores but allows a fresh virtual session', () async {
    await store.saveDocument('station', 'a', {'title': 'old'});
    await db.deleteMusicRecipesForProfile(store.profileId);
    await store.saveDocument('station', 'b', {'title': 'late'});
    await store.record(id: 'late', track: musicTrack('song'), startedAt: now, listenedMs: 30000, finished: true);
    final fresh = MusicLibraryStore(db, store.profileId);
    expect(await fresh.documents('station'), isEmpty);
    expect(await fresh.recent(), isEmpty);
    await fresh.saveDocument('station', 'c', {'title': 'new'});
    expect(await fresh.documents('station'), hasLength(1));
    expect(await store.document('station', 'c'), isNull);
  });
  test('recorder excludes seeking and pause time and counts repeated occurrences', () async {
    final music = ExperienceMusic()..items = [musicTrack('song')];
    var clock = 0;
    final recorder = MusicListeningRecorder(music, store, now: () => now, monotonicMs: () => clock);
    void tick(int ms, int elapsed) {
      clock += elapsed;
      music.positions.add(Duration(milliseconds: ms));
    }

    tick(0, 0);
    tick(10000, 10000);
    music.jumps.add(const Duration(seconds: 40));
    tick(40000, 0);
    tick(50000, 10000);
    music.playing = false;
    music.changed();
    tick(50000, 120000);
    music.playing = true;
    music.changed();
    tick(50000, 0);
    tick(60000, 10000);
    await recorder.flush();
    expect((await chart()).single.listenedMs, 30000);
    music.moveTo(0);
    tick(0, 0);
    tick(30000, 30000);
    await recorder.flush();
    expect((await chart()).single.plays, 2);
    recorder.dispose();
    music.dispose();
    await recorder.flush();
  });
  test('recorder rejects unannounced position jumps beyond elapsed playback', () async {
    final music = ExperienceMusic()..items = [musicTrack('song')];
    var clock = 0;
    final recorder = MusicListeningRecorder(music, store, now: () => now, monotonicMs: () => clock);
    music.positions.add(Duration.zero);
    clock = 1000;
    music.positions.add(const Duration(seconds: 50));
    await recorder.flush();
    expect(await chart(), isEmpty);
    recorder.dispose();
    music.dispose();
  });
}
