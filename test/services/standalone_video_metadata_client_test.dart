import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/standalone_video_metadata_client.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_transport.dart';

void main() {
  for (final byId in [false, true]) {
    test('video metadata accepts Trakt search arrays ${byId ? 'by external ID' : 'by title'}', () async {
      final paths = <String>[];
      final transport = SourceTransport(
        client: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/people')) {
            return http.Response(jsonEncode({'cast': []}), 200);
          }
          return http.Response(
            jsonEncode([
              {
                'type': 'movie',
                'movie': {
                  'title': 'Arrival',
                  'year': 2016,
                  'overview': 'A linguist deciphers an unfamiliar language.',
                  'rating': 8.8,
                  'genres': ['science-fiction'],
                  'ids': {'trakt': 123, 'imdb': 'tt2543164'},
                },
              },
            ]),
            200,
          );
        }),
      );
      addTearDown(transport.close);
      final client = StandaloneVideoMetadataClient(transport: transport);
      final result = await client.identify(
        SourceEntry(
          sourceId: 'local',
          id: 'movie',
          title: 'Arrival.2016.mkv',
          kind: SourceItemKind.video,
          identifiers: byId ? {'imdb': 'tt2543164'} : {},
        ),
      );
      expect(result?.title, 'Arrival');
      expect(result?.year, 2016);
      expect(result?.identifiers['trakt'], '123');
      expect(result?.rating, 8.8);
      expect(result?.genres, ['science-fiction']);
      expect(paths, [byId ? '/search/imdb/tt2543164' : '/search/movie,show', '/movies/123/people']);
    });
  }

  test('metadata lookup sends only the cleaned filename query and selected catalog ID', () async {
    final requests = <http.Request>[];
    final client = StandaloneVideoMetadataClient(
      transport: SourceTransport(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('[]', 200);
        }),
      ),
    );
    addTearDown(client.close);
    const entry = SourceEntry(
      sourceId: 'private-source-id',
      id: 'private-entry-id',
      title: 'PRIVATE_ENTRY_TITLE',
      kind: SourceItemKind.video,
      files: [
        PublicationFile(
          id: 'private-file-id',
          name: '/private/account/PRIVATE_SOURCE_TOKEN/Only.Me.2021.mkv',
          mimeType: 'video/x-matroska',
        ),
      ],
      identifiers: {'tmdb': '12345', 'secret': 'PRIVATE_NFO_CANARY'},
    );

    expect(await client.identify(entry), isNull);
    expect(requests, hasLength(2));
    expect(requests.first.url.path, '/search/tmdb/12345');
    expect(requests.last.url.path, '/search/movie,show');
    expect(requests.last.url.queryParameters['query'], 'Only Me');
    expect(requests.last.url.queryParameters['year'], '2021');
    expect(requests.every((request) => request.method == 'GET' && request.body.isEmpty), isTrue);
    final outbound = requests.map((request) => '${request.url} ${request.headers}').join('\n');
    for (final privateValue in [
      '/private/account',
      'PRIVATE_SOURCE_TOKEN',
      'PRIVATE_ENTRY_TITLE',
      'private-source-id',
      'private-entry-id',
      'private-file-id',
      'PRIVATE_NFO_CANARY',
    ]) {
      expect(outbound, isNot(contains(privateValue)));
    }
  });
}
