import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/music/music_smart_playlist.dart';
import 'package:plezy/services/plex_api_cache.dart';

import '../../test_helpers/backend_client_fixtures.dart';

void main() {
  test('nested expressions preserve duplicate keys, ordering, sort and limits', () {
    const content =
        'server://srv/com.plexapp.plugins.library/library/sections/3/all?type=10&push=1&genre=1&or=1&genre=2&pop=1&and=1&year%3E%3E=2000&sort=titleSort%3Aasc%2Crating%3Adesc&limit=200';
    final rules = MusicSmartPlaylistRules.fromContent(content);
    final restored = MusicSmartPlaylistRules.fromQuery(libraryId: rules.libraryId, query: rules.query);
    expect(restored.parameters, rules.parameters);
    expect(rules.parameters.where((entry) => entry.$1 == 'genre'), [('genre', '1'), ('genre', '2')]);
    expect(rules.parameters.last, ('limit', '200'));
  });

  test('filter form keeps repeated clauses and numeric operator suffixes', () {
    final rules = MusicSmartPlaylistRules.fromFilters(
      libraryId: '3',
      filters: [
        const LibraryFilter(field: 'genre', values: ['1']),
        const LibraryFilter(field: 'genre', values: ['2']),
        const LibraryFilter(field: 'year', op: LibraryFilterOperator.atLeast, values: ['2000']),
      ],
      sort: const LibrarySort(field: 'random'),
      limit: 25,
    );
    expect(rules.parameters.where((entry) => entry.$1 == 'genre'), hasLength(2));
    expect(rules.parameters, contains(('year>>', '2000')));
    expect(rules.query, isNot(contains('Container')));
  });

  test('native audio directory decodes exactly once and preserves filters without an explicit result type', () {
    const path =
        '/library/sections/1224/all?track.addedAt>=-12mon&album.genre!=Podcast'
        '&album.genre!=Books%20%26%20Spoken&artist.title!==Example';
    final content = 'library://22d0bfe3-21ce-4a67-9065-ccaf470cb3c2/directory/${Uri.encodeComponent(path)}';
    final rules = MusicSmartPlaylistRules.fromContent(content, audioPlaylist: true);
    expect(rules.libraryId, '1224');
    expect(rules.parameters, [
      ('type', '10'),
      ('track.addedAt>', '-12mon'),
      ('album.genre!', 'Podcast'),
      ('album.genre!', 'Books & Spoken'),
      ('artist.title!=', 'Example'),
    ]);
    expect(MusicSmartPlaylistRules.fromQuery(libraryId: '1224', query: rules.query).parameters, rules.parameters);
    expect(() => MusicSmartPlaylistRules.fromContent(content), throwsArgumentError);
  });

  test('appending filters keeps modifiers outside nested Boolean clauses', () {
    final rules = MusicSmartPlaylistRules.fromQuery(
      libraryId: '3',
      query: 'type=9&sourceType=8&title==First&or=1&title=%3DSecond&group=title&sort=title:desc&limit=10',
    );
    expect(rules.sourceKind, MediaKind.artist);
    expect(
      rules.appendFilters([
        const LibraryFilter(field: 'genre', values: ['3']),
      ]).parameters,
      [
        ('type', '9'),
        ('sourceType', '8'),
        ('group', 'title'),
        ('sort', 'title:desc'),
        ('limit', '10'),
        ('push', '1'),
        ('title=', 'First'),
        ('or', '1'),
        ('title', '=Second'),
        ('pop', '1'),
        ('genre', '3'),
      ],
    );
  });

  test('malformed groups, credentials and foreign endpoint URIs fail closed', () {
    for (final query in [
      'type=10&pop=1',
      'type=10&push=1',
      'type=10&push=1&pop=1',
      'type=10&or=1&genre=3',
      'type=10&genre=3&or=1&sort=title',
      'type=10&genre=3&or=1&and=1&genre=4',
      'type=1',
      'type=10&type=10',
      'type=10&sourceType=1',
      'type=10&group=title&group=index',
      'type=10&X-Plex-Token=secret',
      'type=10&limit=-1',
    ]) {
      expect(() => MusicSmartPlaylistRules.fromQuery(libraryId: '3', query: query), throwsArgumentError);
    }
    expect(
      () => MusicSmartPlaylistRules.fromContent('https://foreign/library/sections/3/all?type=10'),
      throwsFormatException,
    );
    expect(() => MusicSmartPlaylistRules.fromContent('/library/metadata/42?type=10'), throwsFormatException);
    for (final content in [
      '//foreign/library/sections/3/all?type=10',
      'server://foreign/com.plexapp.plugins.library/library/sections/3/all?type=10',
      'server://srv:123/library/sections/3/all?type=10',
      'library://local/directory/${Uri.encodeComponent('//foreign/library/sections/3/all?type=10')}',
      'library://local/item/${Uri.encodeComponent('/library/sections/3/all?type=10')}',
    ]) {
      expect(() => MusicSmartPlaylistRules.fromContent(content, expectedServer: 'srv'), throwsFormatException);
    }
  });

  test('creation sends a server-owned smart URI, preview stays bounded, update retains smart semantics', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
    final requests = <http.Request>[];
    final rules = MusicSmartPlaylistRules.fromQuery(
      libraryId: '3',
      query: 'type=10&push=1&genre=1&or=1&genre=2&pop=1&limit=25',
    );
    final client = testPlexClient(
      serverId: ServerId('srv'),
      handler: (request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'machineIdentifier': 'srv',
              'totalSize': 1,
              'Metadata': [
                if (request.url.path.contains('/library/sections/'))
                  {'ratingKey': '42', 'type': 'track', 'title': 'Song'}
                else
                  {
                    'ratingKey': '7',
                    'type': 'playlist',
                    'title': 'Smart',
                    'smart': true,
                    'playlistType': 'audio',
                    'content': 'server://srv/com.plexapp.plugins.library${rules.searchPath}',
                  },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
    addTearDown(client.close);
    final playlist = await client.saveSmartMusicPlaylist(title: 'Smart', rules: rules);
    final created = requests.last;
    expect(created.method, 'POST');
    expect(created.url.queryParameters['smart'], '1');
    final uri = created.url.queryParameters['uri']!;
    expect(MusicSmartPlaylistRules.fromContent(uri).parameters, rules.parameters);
    expect(playlist!.smartContent, isNotNull);
    final preview = await client.previewSmartMusicPlaylist(rules);
    expect(preview.items.single.id, '42');
    expect(requests.last.url.query, startsWith('${rules.query}&'));
    expect(requests.last.url.queryParameters['X-Plex-Container-Size'], '50');
    final updated = await client.saveSmartMusicPlaylist(title: 'Smart', rules: rules, playlist: playlist);
    expect(updated!.serverId, 'srv');
    expect(updated.smartContent, isNotNull);
    expect(requests.where((request) => request.method == 'PUT').single.url.path, '/playlists/7/items');
    final count = requests.length;
    await expectLater(
      client.saveSmartMusicPlaylist(title: 'Smart', rules: rules, isCurrent: () => false),
      throwsStateError,
    );
    expect(requests, hasLength(count));
  });
}
