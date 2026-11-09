import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/music/music_discovery.dart';
import '../../test_helpers/media_items.dart';

MediaItem track(String id, {String server = 's', String library = 'lib'}) =>
    testMediaItem(id: id, serverId: server, libraryId: library, kind: MediaKind.track, title: id);

class Client implements MediaServerClient, SonicMusicClient {
  final Map<String, List<MediaItem>> mixes = {};
  final List<(String, String)> paths = [];
  @override
  Future<List<MediaItem>> fetchInstantMix(String id, {int limit = 100}) async => mixes[id] ?? [];
  @override
  Future<List<MediaItem>> sonicPath({required String libraryId, required String startId, required String endId}) async {
    paths.add((startId, endId));
    return [track(startId), track('$startId-$endId'), track(endId)];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('multi-seed mix fairly interleaves, deduplicates and qualifies server IDs', () async {
    final client = Client()
      ..mixes.addAll({
        'a': [track('one'), track('same'), track('three')],
        'b': [track('same'), track('one', server: 'other'), track('four')],
      });
    final recipe = MusicRecipe(
      id: 'mix',
      title: 'Mix',
      kind: MusicRecipeKind.mix,
      seeds: [track('a'), track('b')],
      limit: 4,
    );
    final items = await MusicDiscovery((_) => client).generate(recipe);
    expect(items.map((t) => '${t.serverId}:${t.id}'), ['s:one', 's:same', 'other:one', 's:three']);
  });

  test('ordered adventure preserves all waypoints and joins shared endpoints once', () async {
    final client = Client();
    final recipe = MusicRecipe(
      id: 'trip',
      title: 'Trip',
      kind: MusicRecipeKind.adventure,
      seeds: [track('a'), track('b'), track('c')],
    );
    final items = await MusicDiscovery((_) => client).generate(recipe);
    expect(client.paths, [('a', 'b'), ('b', 'c')]);
    expect(items.map((t) => t.id), ['a', 'a-b', 'b', 'b-c', 'c']);
  });

  test('adventure rejects cross-library seeds and never truncates its destination', () async {
    final client = Client();
    final wrongLibrary = MusicRecipe(
      id: 'x',
      title: 'X',
      kind: MusicRecipeKind.adventure,
      seeds: [
        track('a'),
        track('b', library: 'other'),
      ],
    );
    await expectLater(MusicDiscovery((_) => client).generate(wrongLibrary), throwsArgumentError);
    expect(client.paths, isEmpty);
    final tooShort = MusicRecipe(
      id: 'x',
      title: 'X',
      kind: MusicRecipeKind.adventure,
      seeds: [track('a'), track('b')],
      limit: 2,
    );
    await expectLater(MusicDiscovery((_) => client).generate(tooShort), throwsStateError);
  });

  test('recipe persistence is profile-owned and reloads ordered seeds', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final a = MusicRecipeStore(db, 'a'), b = MusicRecipeStore(db, 'b');
    final recipe = MusicRecipe(id: 'r', title: 'A', kind: MusicRecipeKind.mix, seeds: [track('2'), track('1')]);
    await a.save(recipe);
    expect(await b.load(), isEmpty);
    expect((await a.load()).single.seeds.map((t) => t.id), ['2', '1']);
    await b.delete('r');
    expect(await a.load(), hasLength(1));
    await db.deleteMusicRecipesForProfile('a');
    expect(await a.load(), isEmpty);
  });
}
