import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/services/music/music_library_store.dart';
import 'package:plezy/services/music/music_rating_journal.dart';
import 'package:plezy/media/server_capabilities.dart';

import '../../test_helpers/music_experience_fakes.dart';

class _RatingClient extends ExperienceClient {
  MediaItem? remote;
  @override
  Future<MediaItem?> fetchItem(String id) async => remote ?? musicTrack(id);
}

void main() {
  late AppDatabase db;
  late MusicLibraryStore store;
  late ExperienceClient client;
  late MusicRatingJournal journal;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = MusicLibraryStore(db, 'p');
    client = _RatingClient();
    journal = MusicRatingJournal(store, (_) => client);
  });
  tearDown(() async {
    journal.dispose();
    await db.close();
  });
  test('cold edits survive journal recreation and compare the remote base on reconnect', () async {
    journal.dispose();
    ExperienceClient? available;
    journal = MusicRatingJournal(
      store,
      (_) => available,
      offlineAccountFor: (_) async => (scope: 's/user', capabilities: ServerCapabilities.plex),
    );
    final track = musicTrack('cold').copyWith(userRating: 4);
    expect(await journal.rate(track, 6), isFalse);
    expect(await journal.rate(track, 8), isFalse);
    final pending = (await store.documents('ratingPending')).single;
    expect(pending['base'], 4);
    expect(pending['value'], 8);
    journal.dispose();
    available = client;
    (client as _RatingClient).remote = track.copyWith(userRating: 9);
    journal = MusicRatingJournal(store, (_) => available);
    await journal.sync();
    expect(client.mutations, isEmpty);
    expect((await store.documents('ratingConflict')).single['remote'], 9);
  });
  test('cold edits reject revoked bindings and unsupported favorites', () async {
    journal.dispose();
    var calls = 0;
    journal = MusicRatingJournal(
      store,
      (_) => null,
      offlineAccountFor: (_) async {
        calls++;
        return calls == 1 ? (scope: 's', capabilities: ServerCapabilities.plex) : null;
      },
    );
    await expectLater(journal.rate(musicTrack('a'), 8), throwsStateError);
    expect(await store.documents('ratingPending'), isEmpty);
    calls = 0;
    await expectLater(journal.favorite(musicTrack('a'), true), throwsUnsupportedError);
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

  test('a different device rating requires explicit resolution before overwriting', () async {
    client.isOfflineMode = true;
    await journal.rate(musicTrack('a').copyWith(userRating: 4), 8);
    (client as _RatingClient).remote = musicTrack('a').copyWith(userRating: 9);
    client.isOfflineMode = false;
    await journal.sync();
    expect(client.mutations, isEmpty);
    final conflict = (await store.documents('ratingConflict')).single;
    expect(conflict['base'], 4);
    expect(conflict['remote'], 9);
    expect(await journal.resolveConflict(conflict['id'] as String, 'stale', keepLocal: true), isFalse);
    expect(
      await journal.resolveConflict(conflict['id'] as String, conflict['revision'] as String, keepLocal: true),
      isTrue,
    );
    expect(client.mutations, [('s:a', 8.0)]);
    expect(await store.documents('ratingConflict'), isEmpty);
    expect(await store.documents('ratingPending'), isEmpty);
  });

  test('server choice discards only this revision without writing the server', () async {
    client.isOfflineMode = true;
    await journal.favorite(musicTrack('a').copyWith(isFavorite: false), true);
    (client as _RatingClient).remote = musicTrack('a').copyWith(isFavorite: null);
    client.isOfflineMode = false;
    await journal.sync();
    final conflict = (await store.documents('ratingConflict')).single;
    expect(
      await journal.resolveConflict(conflict['id'] as String, conflict['revision'] as String, keepLocal: false),
      isTrue,
    );
    expect(client.mutations, isEmpty);
    expect(await store.documents('ratingPending'), isEmpty);
  });

  test('a second remote edit invalidates both choices shown for the original conflict', () async {
    client.isOfflineMode = true;
    await journal.rate(musicTrack('a').copyWith(userRating: 4), 8);
    final ratingClient = client as _RatingClient;
    ratingClient.remote = musicTrack('a').copyWith(userRating: 9);
    ratingClient.isOfflineMode = false;
    await journal.sync();
    final first = (await store.documents('ratingConflict')).single;
    final id = first['id'] as String;
    final oldRevision = first['revision'] as String;
    ratingClient.remote = musicTrack('a').copyWith(userRating: 7);

    expect(await journal.resolveConflict(id, oldRevision, keepLocal: true), isFalse);
    expect(await journal.resolveConflict(id, oldRevision, keepLocal: false), isFalse);
    final newer = (await store.documents('ratingConflict')).single;
    expect(newer['remote'], 7);
    expect(newer['revision'], isNot(oldRevision));
    expect(client.mutations, isEmpty);
    expect(await journal.resolveConflict(id, newer['revision'] as String, keepLocal: true), isTrue);
    expect(client.mutations, [('s:a', 8.0)]);
  });

  test('a lost acknowledgement that already reached the server is not replayed', () async {
    client.isOfflineMode = true;
    await journal.rate(musicTrack('a'), 8);
    (client as _RatingClient).remote = musicTrack('a').copyWith(userRating: 8);
    client.isOfflineMode = false;
    await journal.sync();
    expect(client.mutations, isEmpty);
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
  test('sync drains past old and malformed rows without skipping a pending edit', () async {
    for (var i = 0; i < 501; i++) {
      await store.saveDocument('ratingPending', 'legacy-$i', {'version': 1});
    }
    await db.customStatement('INSERT INTO music_documents VALUES (?, ?, ?, ?, ?)', [
      'p',
      'ratingPending',
      'invalid-json',
      '{',
      DateTime.now().millisecondsSinceEpoch + 1000,
    ]);
    client.isOfflineMode = true;
    await journal.rate(musicTrack('current'), 8);
    client.isOfflineMode = false;
    await journal.sync();
    expect(client.mutations, [('s:current', 8.0)]);
    await journal.sync();
    expect(client.mutations, [('s:current', 8.0)]);
  });
}
