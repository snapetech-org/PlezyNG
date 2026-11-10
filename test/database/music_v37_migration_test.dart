import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/music/music_discovery.dart';
import 'package:plezy/services/music/music_library_store.dart';
import '../../test/test_helpers/music_experience_fakes.dart';

void main() {
  test('v36 upgrade preserves recipes and creates isolated history/documents for virtual profiles', () async {
    final directory = await Directory.systemTemp.createTemp('pleazyng-music-v37');
    final file = File('${directory.path}/database.sqlite');
    var database = AppDatabase.forTesting(NativeDatabase(file));
    try {
      final recipe = MusicRecipe(id: 'r', title: 'Saved mix', kind: MusicRecipeKind.mix, seeds: [musicTrack('a')]);
      await MusicRecipeStore(database, 'virtual-profile').save(recipe);
      await database.customStatement('DROP TABLE music_listens');
      await database.customStatement('DROP TABLE music_documents');
      await database.customStatement('PRAGMA user_version = 36');
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));
      expect((await MusicRecipeStore(database, 'virtual-profile').load()).single.title, 'Saved mix');
      final store = MusicLibraryStore(database, 'virtual-profile');
      await store.record(
        id: 'listen',
        track: musicTrack('a'),
        startedAt: DateTime(2026),
        listenedMs: 40000,
        finished: true,
      );
      await store.saveDocument('station', 'a', {'version': 1});
      expect(await store.recent(), hasLength(1));
      expect(await MusicLibraryStore(database, 'other-profile').recent(), isEmpty);
      await database.deleteMusicRecipesForProfile('virtual-profile');
      await store.saveDocument('station', 'late', {'version': 1});
      expect(await MusicLibraryStore(database, 'virtual-profile').recent(), isEmpty);
      expect(await MusicLibraryStore(database, 'virtual-profile').documents('station'), isEmpty);
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });
}
