import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/music/music_discovery.dart';
import '../../test_helpers/media_items.dart';
import '../../test_helpers/music_experience_fakes.dart';

MediaItem track(String id, {String server = 's', String library = 'lib'}) =>
    testMediaItem(id: id, serverId: server, libraryId: library, kind: MediaKind.track, title: id);

class Client extends ExperienceClient {
  Client({String server = 's'}) : serverId = ServerId(server);

  @override
  final ServerId serverId;
  final Map<String, List<MediaItem>> mixes = {};
  final List<(String, String)> paths = [];
  Future<List<MediaItem>> Function(String)? fetchMix;
  @override
  Future<List<MediaItem>> fetchInstantMix(String id, {int limit = 100}) async {
    if (fetchMix case final fetch?) return fetch(id);
    return mixes[id] ?? [];
  }

  @override
  Future<List<MediaItem>> sonicPath({required String libraryId, required String startId, required String endId}) async {
    paths.add((startId, endId));
    return [track(startId), track('$startId-$endId'), track(endId)];
  }
}

void main() {
  test('multi-seed mix fairly interleaves, deduplicates and qualifies server IDs', () async {
    final client = Client()..mixes['a'] = [track('one'), track('same'), track('same'), track('three')];
    final other = Client(server: 'other')
      ..mixes['b'] = [track('wrong'), track('one', server: 'other'), track('four', server: 'other')];
    final recipe = MusicRecipe(
      id: 'mix',
      title: 'Mix',
      kind: MusicRecipeKind.mix,
      seeds: [
        track('a'),
        track('b', server: 'other'),
      ],
      limit: 4,
    );
    final result = await MusicDiscovery((item) => item.serverId == 's' ? client : other).generate(recipe);
    expect(result.tracks.map((item) => '${item.serverId}:${item.id}'), ['s:one', 'other:one', 's:same', 'other:four']);
    expect(result.isCurrent(), isTrue);
    other.authenticationSessionId = Object();
    expect(result.isCurrent(), isFalse);
  });

  test('a seed already fetched cannot outlive its account when another request finishes', () async {
    final first = Client()..mixes['first'] = [track('earlier')];
    final started = Completer<void>();
    final response = Completer<List<MediaItem>>();
    final later = Client(server: 'later')
      ..fetchMix = (_) {
        started.complete();
        return response.future;
      };
    final recipe = MusicRecipe(
      id: 'mixed',
      title: 'Mixed',
      kind: MusicRecipeKind.mix,
      seeds: [
        track('first'),
        track('later', server: 'later'),
      ],
    );
    final generation = MusicDiscovery((item) => item.serverId == 's' ? first : later).generate(recipe);
    final rejected = expectLater(generation, throwsStateError);
    await started.future;
    first.authenticationSessionId = Object();
    response.complete([track('later-row', server: 'later')]);
    await rejected;
  });

  test('ordered adventure preserves all waypoints and joins shared endpoints once', () async {
    final client = Client();
    final recipe = MusicRecipe(
      id: 'trip',
      title: 'Trip',
      kind: MusicRecipeKind.adventure,
      seeds: [track('a'), track('b'), track('c')],
    );
    final result = await MusicDiscovery((_) => client).generate(recipe);
    expect(client.paths, [('a', 'b'), ('b', 'c')]);
    expect(result.tracks.map((track) => track.id), ['a', 'a-b', 'b', 'b-c', 'c']);
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
    await a.save(recipe);
    expect(await MusicRecipeStore(db, 'a').load(), isEmpty);
  });
}
