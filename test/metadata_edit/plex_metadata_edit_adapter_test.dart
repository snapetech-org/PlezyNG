import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/metadata_edit/metadata_edit_models.dart';
import 'package:plezy/metadata_edit/plex_metadata_edit_adapter.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/plex_api_cache.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';
import '../test_helpers/media_items.dart';

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(database);
    addTearDown(database.close);
  });

  test('music collection metadata uses type 18 and square poster plus background without preferences', () async {
    final requests = <http.Request>[];
    final client = testPlexClient(
      serverId: ServerId('server-1'),
      handler: (request) async {
        requests.add(request);
        if (request.method == 'PUT') return http.Response('', 200);
        return jsonResponse({
          'MediaContainer': {
            'Metadata': [
              {
                'ratingKey': 'collection',
                'type': 'collection',
                'subtype': 'album',
                'title': 'Collection',
                'summary': 'Old summary',
                'librarySectionID': 1,
              },
            ],
          },
        });
      },
    );
    addTearDown(client.close);
    final adapter = PlexMetadataEditAdapter(client);
    final item = testMediaItem(id: 'collection', kind: MediaKind.collection, serverId: 'server-1', libraryId: '1');
    expect(adapter.supportsKind(item.kind), isTrue);
    final draft = await adapter.load(item);
    expect(requests.where((r) => r.url.queryParameters.containsKey('includePreferences')), isEmpty);
    final sections = adapter.buildSchema(draft);
    expect(sections.map((s) => s.id), ['basic', 'artwork']);
    expect(sections.first.fields.map((f) => f.id), ['title', 'titleSort', 'summary']);
    final art = sections.last.fields;
    expect(art.map((f) => f.artwork!.key), ['posters', 'arts']);
    expect(art.first.artwork!.gridAspectRatio, 1);
    draft.setValue('summary', 'Updated collection summary');
    expect(await adapter.save(draft), isTrue);
    final save = requests.last;
    expect(save.url.path, '/library/sections/1/all');
    expect(save.url.queryParameters['type'], '18');
    expect(save.url.queryParameters['summary.value'], 'Updated collection summary');
    expect(save.url.queryParameters.containsKey('title.value'), isFalse);
    expect(await adapter.applyArtworkFromUrl(draft, art.first, 'https://example.com/cover.jpg'), isTrue);
    expect(requests.last.url.path, '/library/metadata/collection/poster');
    expect(await adapter.uploadArtwork(draft, art.last, [1, 2, 3]), isTrue);
    expect(requests.last.url.path, '/library/metadata/collection/art');
    expect(requests.last.bodyBytes, [1, 2, 3]);
  });

  test('collection load rejects an item from another library or media kind', () async {
    for (final wrongKind in [false, true]) {
      final client = testPlexClient(
        serverId: ServerId('server-1'),
        handler: (_) async => jsonResponse({
          'MediaContainer': {
            'Metadata': [
              {
                'ratingKey': 'collection',
                'type': wrongKind ? 'album' : 'collection',
                'title': 'Collection',
                'librarySectionID': wrongKind ? 1 : 2,
              },
            ],
          },
        }),
      );
      final adapter = PlexMetadataEditAdapter(client);
      final item = testMediaItem(id: 'collection', kind: MediaKind.collection, serverId: 'server-1', libraryId: '1');
      await expectLater(adapter.load(item), throwsStateError);
      client.close();
    }
  });

  test('collection empty and oversized title edits fail before a request', () async {
    var writes = 0;
    final client = testPlexClient(
      handler: (_) async {
        writes++;
        return http.Response('', 200);
      },
    );
    addTearDown(client.close);
    final adapter = PlexMetadataEditAdapter(client);
    final item = testMediaItem(id: 'collection', kind: MediaKind.collection, libraryId: '1');
    for (final title in ['  ', List.filled(256, 'x').join()]) {
      final draft = MetadataEditDraft(sourceItem: item, currentItem: item, values: {'title': 'Original'});
      draft.setValue('title', title);
      expect(await adapter.save(draft), isFalse);
    }
    expect(writes, 0);
  });

  test('label suggestions come from the section label filter facet', () async {
    final client = testPlexClient(
      serverId: ServerId('server-1'),
      handler: (request) async {
        if (request.url.path == '/library/sections/1/filters') {
          return jsonResponse({
            'MediaContainer': {
              'Directory': [
                {'filter': 'genre', 'filterType': 'string', 'key': '/library/sections/1/genre', 'title': 'Genre'},
                {'filter': 'label', 'filterType': 'string', 'key': '/library/sections/1/label', 'title': 'Label'},
              ],
            },
          });
        }
        if (request.url.path == '/library/sections/1/label') {
          return jsonResponse({
            'MediaContainer': {
              'Directory': [
                {'key': '42', 'title': 'kids'},
                {'key': '43', 'title': 'horror'},
              ],
            },
          });
        }
        return http.Response('unexpected ${request.url}', 404);
      },
    );
    addTearDown(client.close);

    final adapter = PlexMetadataEditAdapter(client);
    final item = testMediaItem(
      id: 'movie-1',
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      libraryId: '1',
      serverId: 'server-1',
    );
    final draft = MetadataEditDraft(sourceItem: item, currentItem: item, values: {});
    final labelField = adapter.buildSchema(draft).expand((s) => s.fields).singleWhere((f) => f.id == 'label');

    expect(await adapter.fetchTagSuggestions(draft, labelField), ['kids', 'horror']);
  });

  test('a section without a label facet returns no suggestions', () async {
    final client = testPlexClient(
      serverId: ServerId('server-1'),
      handler: (request) async {
        if (request.url.path == '/library/sections/1/filters') {
          return jsonResponse({
            'MediaContainer': {
              'Directory': [
                {'filter': 'genre', 'filterType': 'string', 'key': '/library/sections/1/genre', 'title': 'Genre'},
              ],
            },
          });
        }
        return http.Response('unexpected ${request.url}', 404);
      },
    );
    addTearDown(client.close);

    final adapter = PlexMetadataEditAdapter(client);
    final item = testMediaItem(
      id: 'movie-1',
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      libraryId: '1',
      serverId: 'server-1',
    );
    final draft = MetadataEditDraft(sourceItem: item, currentItem: item, values: {});
    final labelField = adapter.buildSchema(draft).expand((s) => s.fields).singleWhere((f) => f.id == 'label');

    expect(await adapter.fetchTagSuggestions(draft, labelField), isEmpty);
  });

  test('an item without a library id skips the facet lookup', () async {
    var called = false;
    final client = testPlexClient(
      serverId: ServerId('server-1'),
      handler: (request) async {
        called = true;
        return http.Response('', 404);
      },
    );
    addTearDown(client.close);

    final adapter = PlexMetadataEditAdapter(client);
    final item = testMediaItem(id: 'movie-1', backend: MediaBackend.plex, kind: MediaKind.movie, serverId: 'server-1');
    final draft = MetadataEditDraft(sourceItem: item, currentItem: item, values: {});
    final labelField = adapter.buildSchema(draft).expand((s) => s.fields).singleWhere((f) => f.id == 'label');

    expect(await adapter.fetchTagSuggestions(draft, labelField), isEmpty);
    expect(called, isFalse);
  });
}
