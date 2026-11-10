import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/music/music_library_store.dart';
import 'package:plezy/services/music/music_search_history.dart';

void main() {
  late AppDatabase database;
  late MusicLibraryStore store;
  late MusicSearchHistory history;
  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    store = MusicLibraryStore(database, 'profile');
    history = MusicSearchHistory(store);
  });
  tearDown(() => database.close());

  test('queries are bounded, trimmed, deduplicated and most recent first', () async {
    for (var index = 0; index < 25; index++) {
      await history.record(' query $index ');
    }
    await history.record('QUERY 15');
    final queries = await history.load();
    expect(queries, hasLength(20));
    expect(queries.first, 'QUERY 15');
    expect(queries.where((query) => query.toLowerCase() == 'query 15'), hasLength(1));
    await history.record(' ');
    await history.record('x' * 257);
    expect(await history.load(), queries);
  });

  test('concurrent screens cannot overwrite one another and removal stays profile scoped', () async {
    final second = MusicSearchHistory(store);
    await Future.wait([history.record('first'), second.record('second')]);
    expect(await history.load(), containsAll(['first', 'second']));
    final other = MusicSearchHistory(MusicLibraryStore(database, 'other'));
    expect(await other.load(), isEmpty);
    await other.record('private');
    await history.remove('FIRST');
    expect(await history.load(), ['second']);
    await history.clear();
    expect(await history.load(), isEmpty);
    expect(await other.load(), ['private']);
  });

  test('malformed stored entries and future versions fail closed', () async {
    await store.saveDocument('search', 'recent', {
      'version': 1,
      'queries': [1, '', 'valid', 'VALID', 'x' * 257],
    });
    expect(await history.load(), ['valid']);
    await store.saveDocument('search', 'recent', {
      'version': 2,
      'queries': ['future'],
    });
    expect(await history.load(), isEmpty);
  });

  test('deleted profiles cannot restore history through old services', () async {
    await history.record('before');
    await database.deleteMusicRecipesForProfile('profile');
    await history.record('late');
    expect(await MusicSearchHistory(MusicLibraryStore(database, 'profile')).load(), isEmpty);
  });
}
