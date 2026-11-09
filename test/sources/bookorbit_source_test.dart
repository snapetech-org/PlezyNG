import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/sources/adapters/bookorbit_source.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_transport.dart';

http.Response jsonResponse(Object? value, {int status = 200}) =>
    http.Response(jsonEncode(value), status, headers: const {'content-type': 'application/json'});

void main() {
  test('BookOrbit browses, opens both formats, and synchronizes audio position', () async {
    final seen = <http.Request>[];
    final transport = SourceTransport(
      client: MockClient((request) async {
        seen.add(request);
        switch (request.url.path) {
          case '/books/api/v1/auth/login':
            expect(request.method, 'POST');
            expect(jsonDecode(request.body)['clientKind'], 'native');
            return jsonResponse({'accessToken': 'private-access-token'});
          case '/books/api/v1/books/query':
            expect(request.headers['authorization'], 'Bearer private-access-token');
            expect(jsonDecode(request.body)['pagination'], {'page': 0, 'size': 100});
            return jsonResponse({
              'items': [
                {
                  'id': 5,
                  'title': 'The Orbit',
                  'authors': ['Writer'],
                  'hasCover': true,
                  'seriesName': 'Orbit Trilogy',
                  'seriesIndex': '2.5',
                  'isbn13': '9781234567897',
                  'files': [
                    {'id': 10, 'role': 'content', 'format': 'epub', 'sizeBytes': 100},
                    {'id': 11, 'role': 'content', 'format': 'm4b', 'sizeBytes': 200},
                  ],
                },
              ],
              'total': 1,
            });
          case '/books/api/v1/books/5':
            return jsonResponse({
              'id': 5,
              'title': 'The Orbit',
              'authors': [
                {'id': 2, 'name': 'Writer', 'sortName': 'Writer'},
              ],
              'audioMetadata': {
                'narrators': [
                  {'id': 3, 'name': 'Narrator'},
                ],
              },
              'description': 'A journey across the shelves.',
              'coverSource': 'extracted',
              'seriesName': 'Orbit Trilogy',
              'seriesIndex': '2.5',
              'providerIds': {'hardcover': '12345', 'openlibrary': 'OL82563W'},
              'files': [
                {'id': 10, 'role': 'content', 'format': 'epub', 'sizeBytes': 100},
                {'id': 11, 'role': 'content', 'format': 'm4b', 'sizeBytes': 200},
              ],
            });
          case '/books/api/v1/audiobooks/5/manifest':
            return jsonResponse({
              'assets': [
                {'fileId': 11, 'assetId': 'aud_123e4567-e89b-42d3-a456-426614174000', 'durationMs': 60000},
              ],
            });
          case '/books/api/v1/books/5/audio-progress':
            if (request.method == 'GET') {
              return jsonResponse({'currentFileId': 11, 'positionSeconds': 12, 'percentage': 20});
            }
            expect(jsonDecode(request.body), {'currentFileId': 11, 'positionSeconds': 12.0, 'percentage': 20.0});
            return http.Response('', 204);
          default:
            return http.Response('', 404);
        }
      }),
    );
    final adapter = BookOrbitSourceAdapter(
      const FileSource(
        id: 'orbit',
        profileId: 'person',
        kind: FileSourceKind.bookorbit,
        name: 'BookOrbit',
        endpoint: 'https://books.example/books/',
      ),
      transport,
      () async => {'username': 'reader', 'password': 'secret'},
    );
    try {
      final page = await adapter.browse();
      final entry = page.entries.single;
      expect(entry.kind, SourceItemKind.audiobook);
      expect(entry.ebooks.length, 1);
      expect(entry.audio.length, 1);
      expect(entry.identifiers['isbn13'], '9781234567897');
      final hydrated = await adapter.hydrate(entry);
      expect(hydrated.author, 'Writer');
      expect(hydrated.narrator, 'Narrator');
      expect(hydrated.description, 'A journey across the shelves.');
      expect(hydrated.series, 'Orbit Trilogy');
      expect(hydrated.seriesOrder, 2.5);
      expect(hydrated.coverId, '5');
      expect(hydrated.identifiers['isbn13'], '9781234567897');
      expect(hydrated.identifiers['hardcover'], '12345');
      expect(hydrated.identifiers['openlibrary'], 'OL82563W');
      expect((await adapter.cover(hydrated))?.uri.path, '/books/api/v1/books/5/cover');
      final ebook = await adapter.resolve(hydrated.ebooks.single);
      final audio = await adapter.resolve(hydrated.audio.single);
      expect(ebook.uri.path, '/books/api/v1/books/files/10/serve');
      expect(audio.uri.path, '/books/api/v1/audiobooks/5/assets/aud_123e4567-e89b-42d3-a456-426614174000/content');
      expect(audio.headers['Authorization'], 'Bearer private-access-token');
      final local = PublicationProgress(
        entryKey: hydrated.key,
        edition: 'audio',
        mode: PublicationMode.listening,
        session: 'local',
      );
      final remote = await adapter.readProgress(hydrated, local);
      expect(remote?.positionMs, 12000);
      expect(remote?.fraction, .2);
      await adapter.writeProgress(hydrated, remote!);
      expect(seen.where((request) => request.url.path.endsWith('/auth/login')).length, 1);
      expect(jsonEncode(entry.toJson()), isNot(contains('private-access-token')));
      expect(jsonEncode(entry.toJson()), isNot(contains('secret')));
    } finally {
      adapter.close();
    }
  });

  test('BookOrbit refuses credentials and never follows an untrusted endpoint', () async {
    final transport = SourceTransport(client: MockClient((_) async => http.Response('', 401)));
    final adapter = BookOrbitSourceAdapter(
      const FileSource(
        id: 'orbit',
        profileId: 'person',
        kind: FileSourceKind.bookorbit,
        name: 'BookOrbit',
        endpoint: 'https://books.example/',
      ),
      transport,
      () async => {'username': 'reader', 'password': 'wrong'},
    );
    await expectLater(adapter.browse(), throwsA(isA<SourceException>()));
    adapter.close();
  });
}
