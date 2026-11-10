import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/music/music_library_store.dart';
import 'package:plezy/services/music/music_rating_journal.dart';
import '../../test_helpers/music_experience_fakes.dart';

void main() {
  late AppDatabase db;
  late MusicLibraryStore store;
  late ExperienceClient client;
  late MusicRatingJournal journal;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = MusicLibraryStore(db, 'p');
    client = ExperienceClient();
    journal = MusicRatingJournal(store, (_) => client);
  });
  tearDown(() async {
    journal.dispose();
    await db.close();
  });
  test('offline edits coalesce to the last decision and sync idempotently', () async {
    client.isOfflineMode = true;
    expect(await journal.rate(musicTrack('a'), 3), isFalse);
    expect(await journal.rate(musicTrack('a'), 8), isFalse);
    expect(await store.documents('ratingPending'), hasLength(1));
    expect(client.mutations, isEmpty);
    client.isOfflineMode = false;
    await journal.sync();
    await journal.sync();
    expect(client.mutations, [('s:a', 8.0)]);
    expect(await store.documents('ratingPending'), isEmpty);
  });
  test('a changed account cannot receive a previous account pending rating', () async {
    client.isOfflineMode = true;
    await journal.favorite(musicTrack('a'), true);
    client.isOfflineMode = false;
    client.scopedServerId = 's/other-user';
    await journal.sync();
    expect(client.mutations, isEmpty);
    expect(await store.documents('ratingPending'), hasLength(1));
  });
  test('two accounts retain separate edits for the same track', () async {
    client.isOfflineMode = true;
    await journal.rate(musicTrack('a'), 3);
    client.scopedServerId = 's/second-user';
    await journal.rate(musicTrack('a'), 8);
    expect(await store.documents('ratingPending'), hasLength(2));
    client.isOfflineMode = false;
    await journal.sync();
    expect(client.mutations, [('s:a', 8.0)]);
    expect(await store.documents('ratingPending'), hasLength(1));
    client.scopedServerId = 's/user';
    await journal.sync();
    expect(client.mutations, [('s:a', 8.0), ('s:a', 3.0)]);
  });
  test('a changed authentication session cannot acknowledge an earlier write', () async {
    client.onRate = () async {
      client.authenticationSessionId = Object();
    };
    expect(await journal.rate(musicTrack('a'), 9), isFalse);
    expect(await store.documents('ratingPending'), hasLength(1));
  });
  test('network failure retains an edit and newer input wins after reconnection', () async {
    client.onRate = () async {
      throw StateError('offline');
    };
    expect(await journal.rate(musicTrack('a'), 2), isFalse);
    client.onRate = null;
    expect(await journal.rate(musicTrack('a'), 7), isTrue);
    await journal.sync();
    expect(client.mutations, [('s:a', 2.0), ('s:a', 7.0)]);
  });
  test('queued operations cannot resurrect removed profile records', () async {
    final ack = Completer<void>();
    client.onRate = () => ack.future;
    final first = journal.rate(musicTrack('a'), 3);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final second = journal.rate(musicTrack('b'), 8);
    await db.deleteMusicRecipesForProfile('p');
    journal.dispose();
    ack.complete();
    await first;
    await expectLater(second, throwsStateError);
    expect(await MusicLibraryStore(db, 'p').documents('ratingPending'), isEmpty);
  });
  test('invalid ratings never enter the journal', () async {
    for (final value in [double.nan, -0.5, 11.0]) {
      await expectLater(journal.rate(musicTrack('a'), value), throwsArgumentError);
    }
    expect(await store.documents('ratingPending'), isEmpty);
  });
}
