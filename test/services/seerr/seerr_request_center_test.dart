import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/models/seerr/seerr_media.dart';
import 'package:plezy/models/seerr/seerr_request_item.dart';
import 'package:plezy/models/seerr/seerr_session.dart';
import 'package:plezy/services/seerr/seerr_client.dart';
import 'package:plezy/services/seerr/seerr_constants.dart';
import 'package:plezy/services/seerr/seerr_exceptions.dart';

SeerrClient clientFor(
  Future<http.Response> Function(http.Request) handler, {
  int permissions = SeerrPermission.request,
}) {
  final client = SeerrClient(
    const SeerrSession(
      baseUrl: 'https://seerr.example.com',
      method: SeerrAuthMethod.local,
      identifier: '',
      secret: '',
      cookie: 'profile-cookie',
      userId: 7,
      permissions: SeerrPermission.request,
      displayName: 'User',
      instanceLabel: 'SeerrNG',
      product: SeerrProduct.jellyseerr,
      createdAt: 0,
    ).copyWith(permissions: permissions),
    onSessionInvalidated: () {},
    httpClient: MockClient(handler),
  );
  addTearDown(client.dispose);
  return client;
}

http.Response json(Object data) => http.Response(jsonEncode(data), 200, headers: {'content-type': 'application/json'});

void main() {
  for (final category in SeerrRequestCategory.values) {
    test('discovers and searches ${category.name} through the signed-in instance', () async {
      final calls = <http.Request>[];
      final client = clientFor((request) async {
        calls.add(request);
        return json({
          'page': 1,
          'totalPages': 2,
          'results': [
            {'id': category.isBook ? 'OL123W' : 123, 'title': 'Title', 'mediaType': category.mediaType},
          ],
        });
      });
      expect((await client.browseRequests(category, discover: true)).items.single.title, 'Title');
      expect(
        calls.last.url.path,
        '/api/v1/discover/${category.isBook
            ? 'books'
            : category == SeerrRequestCategory.movies
            ? 'movies'
            : 'tv'}',
      );
      expect(calls.last.url.queryParameters['format'], category.format);
      expect(calls.last.headers['cookie'], contains('profile-cookie'));
      final page = await client.browseRequests(category, query: 'a title', page: 2);
      expect(page.hasMore, isFalse);
      expect(calls.last.url.path, '/api/v1/search');
      expect(calls.last.url.queryParameters['query'], 'a title');
      expect(calls.last.url.queryParameters['type'], category.mediaType);
      expect(calls.last.url.queryParameters['format'], category.format);
    });
  }

  test('own book overview filters owner and format and hydrates only visible requests', () async {
    final calls = <http.Request>[];
    final client = clientFor((request) async {
      calls.add(request);
      if (request.url.path.endsWith('/request/status')) {
        expect(request.url.queryParameters['requestedBy'], '7');
        expect(request.url.queryParameters['bookFormat'], 'audiobook');
        expect(request.url.queryParameters['skip'], '20');
        return json({
          'pageInfo': {'pages': 3},
          'results': [
            for (final owner in [7, 99])
              {
                'request': {
                  'id': owner,
                  'type': 'book',
                  'status': 1,
                  'requestedBy': {'id': owner},
                  'media': {
                    'status': 2,
                    'identifiers': [
                      {'provider': 'openlibrary', 'value': 'OL123W'},
                    ],
                  },
                },
              },
          ],
        });
      }
      return json({'id': 'OL123W', 'title': 'Book'});
    });
    final page = await client.browseRequests(SeerrRequestCategory.audiobooks, page: 2);
    expect(page.items.single.title, 'Book');
    expect(page.items.single.isRequested(SeerrProduct.jellyseerr), isTrue);
    expect(page.hasMore, isTrue);
    expect(calls, hasLength(2));
  });

  for (final category in [SeerrRequestCategory.ebooks, SeerrRequestCategory.audiobooks]) {
    test('${category.name} request sends only identity and format, without admin overrides', () async {
      final client = clientFor((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/request');
        expect(jsonDecode(request.body), {'mediaType': 'book', 'mediaId': 'OL123W', 'format': category.format});
        return json({'id': 1});
      }, permissions: SeerrPermission.requestBook);
      await client.requestBook(SeerrRequestItem(id: 'OL123W', category: category, title: 'Book'));
    });
  }

  test('overview refresh reuses account-local titles but refreshes request status', () async {
    var detailsReads = 0;
    var status = 1;
    final client = clientFor((request) async {
      if (request.url.path.endsWith('/request')) {
        return json({
          'results': [
            {
              'type': 'movie',
              'status': status,
              'requestedBy': {'id': 7},
              'media': {'tmdbId': 123, 'status': status == 1 ? 2 : 5},
            },
          ],
        });
      }
      detailsReads++;
      return json({'id': 123, 'title': 'Cached title'});
    });
    expect((await client.browseRequests(SeerrRequestCategory.movies)).items.single.requestStatus, 1);
    status = 5;
    final refreshed = (await client.browseRequests(SeerrRequestCategory.movies)).items.single;
    expect(refreshed.status(SeerrProduct.jellyseerr), SeerrMediaStatus.available);
    expect(detailsReads, 1);
  });

  test('missing metadata does not discard the users request history', () async {
    final client = clientFor((request) async {
      if (request.url.path.endsWith('/request')) {
        return json({
          'results': [
            {
              'type': 'movie',
              'status': 1,
              'requestedBy': {'id': 7},
              'media': {'tmdbId': 123, 'status': 2},
            },
          ],
        });
      }
      return http.Response('{"message":"Not found"}', 404, headers: {'content-type': 'application/json'});
    });
    final page = await client.browseRequests(SeerrRequestCategory.movies);
    expect(page.items.single.id, 123);
    expect(page.items.single.isRequested(SeerrProduct.jellyseerr), isTrue);
  });

  test('own 4K request status and details do not reuse standard availability', () async {
    final client = clientFor((request) async {
      if (request.url.path.endsWith('/request')) {
        return json({
          'pageInfo': {'pages': 1},
          'results': [
            {
              'type': 'movie',
              'status': 2,
              'is4k': true,
              'requestedBy': {'id': 7},
              'media': {'tmdbId': 123, 'status': 5, 'status4k': 3},
            },
          ],
        });
      }
      return json({
        'id': 123,
        'title': 'Movie',
        'mediaInfo': {'status': 5, 'status4k': 3},
      });
    });
    final item = (await client.browseRequests(SeerrRequestCategory.movies)).items.single;
    expect(item.is4k, isTrue);
    expect(item.status(SeerrProduct.jellyseerr), SeerrMediaStatus.processing);
    final details = await client.requestDetails(item);
    expect(details.is4k, isTrue);
    expect(details.status(SeerrProduct.jellyseerr), SeerrMediaStatus.processing);
  });

  test('revoked book permission prevents even sending a mutation', () async {
    final client = clientFor((_) async => fail('No HTTP call is allowed'), permissions: 0);
    await expectLater(
      client.requestBook(const SeerrRequestItem(id: 'OL123W', category: SeerrRequestCategory.ebooks, title: 'Book')),
      throwsA(isA<SeerrAuthException>()),
    );
  });

  test('ebook availability and pending requests do not cover the audiobook format', () {
    const info = <String, dynamic>{
      'status': 5,
      'externalServiceId': 1,
      'requests': [
        {'status': 1, 'bookFormat': 'ebook'},
      ],
    };
    const ebook = SeerrRequestItem(id: 'OL123W', category: SeerrRequestCategory.ebooks, title: 'Book', mediaInfo: info);
    const audio = SeerrRequestItem(
      id: 'OL123W',
      category: SeerrRequestCategory.audiobooks,
      title: 'Book',
      mediaInfo: info,
    );
    expect(ebook.status(SeerrProduct.jellyseerr), SeerrMediaStatus.available);
    expect(audio.status(SeerrProduct.jellyseerr), SeerrMediaStatus.unknown);
    expect(audio.isRequested(SeerrProduct.jellyseerr), isFalse);
  });
}
