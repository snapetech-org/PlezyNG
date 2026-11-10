import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_client.dart';

import '../test_helpers/backend_client_fixtures.dart';

Map<String, Object> _entry(int event, {int account = 1, int section = 3, String type = 'track'}) => {
  'historyKey': '/status/sessions/history/$event',
  'accountID': account,
  'ratingKey': '42',
  'type': type,
  'librarySectionID': '$section',
  'title': 'Song',
  'grandparentTitle': 'Artist',
  'viewedAt': 1760000000,
  'thumb': 'https://private.example/art?X-Plex-Token=never-export',
};

http.Response _page(List<Map<String, Object>> rows, {int offset = 0, int? total}) => http.Response(
  jsonEncode({
    'MediaContainer': {'Metadata': rows, 'offset': offset, 'size': rows.length, 'totalSize': total ?? rows.length},
  }),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  late AppDatabase database;
  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(database);
  });
  tearDown(() => database.close());

  PlexClient client(Future<http.Response> Function(http.Request) request) {
    final result = testPlexClient(serverId: ServerId('server'), handler: request)
      ..plexAccountId = 'plex.owner'
      ..plexMusicUserIdentifier = 'owner'
      ..bindMusicHistoryResource(owned: true);
    addTearDown(result.close);
    return result;
  }

  test('history pages are server-, owner- and section-scoped and preserve repeated plays', () async {
    final history = client((request) async {
      final query = request.url.queryParameters;
      expect(request.url.path, '/status/sessions/history/all');
      expect(query['accountID'], '1');
      expect(query['librarySectionID'], '3');
      expect(query['sort'], 'viewedAt:desc');
      expect(query['X-Plex-Container-Size'], '50');
      expect(request.headers['x-plex-token'], 'token');
      return switch (query['X-Plex-Container-Start']) {
        '0' => _page([_entry(4), _entry(3, type: 'album'), _entry(2)], total: 4),
        '3' => _page([_entry(1)], offset: 3, total: 4),
        _ => throw StateError('Unexpected history offset'),
      };
    });
    final first = await history.fetchMusicServerHistory(libraryId: '3');
    expect(first.nextStart, 3);
    expect(first.entries.map((entry) => entry.id), ['4', '2']);
    expect(first.entries.map((entry) => entry.item.id), ['42', '42']);
    expect(first.entries.first.item.serverId, 'server');
    expect(first.entries.first.item.libraryId, '3');
    expect(first.entries.first.item.trackArtistTitle, 'Artist');
    expect(first.entries.first.item.thumbPath, isNull);
    expect(first.entries.first.item.raw, isNull);
    final second = await history.fetchMusicServerHistory(libraryId: '3', start: first.nextStart!);
    expect(second.entries.single.id, '1');
    expect(second.nextStart, isNull);
  });

  test('unverified direct, managed and shared bindings never request history', () async {
    final history = client((_) async => throw StateError('Unexpected HTTP request'));
    expect(history.supportsMusicServerHistory, isTrue);
    history
      ..plexMusicUserIdentifier = 'managed'
      ..bindMusicHistoryResource(owned: true);
    expect(history.supportsMusicServerHistory, isFalse);
    await expectLater(history.fetchMusicServerHistory(libraryId: '3'), throwsStateError);
    history
      ..plexMusicUserIdentifier = 'owner'
      ..bindMusicHistoryResource(owned: false);
    expect(history.supportsMusicServerHistory, isFalse);
    history
      ..plexMusicUserIdentifier = null
      ..bindMusicHistoryResource(owned: true);
    expect(history.supportsMusicServerHistory, isFalse);
  });

  test('history rejects other users, hidden section results and stalled paging', () async {
    var result = _page([_entry(1, account: 2)]);
    final history = client((_) async => result);
    await expectLater(history.fetchMusicServerHistory(libraryId: '3'), throwsFormatException);
    result = _page([_entry(1, section: 4)]);
    await expectLater(history.fetchMusicServerHistory(libraryId: '3'), throwsFormatException);
    result = _page([_entry(1)], offset: 4, total: 5);
    await expectLater(history.fetchMusicServerHistory(libraryId: '3'), throwsFormatException);
    result = _page([], total: 1);
    await expectLater(history.fetchMusicServerHistory(libraryId: '3'), throwsFormatException);
  });

  test('revocation while the request is in flight rejects the old response', () async {
    final sent = Completer<void>();
    final response = Completer<http.Response>();
    final history = client((_) {
      sent.complete();
      return response.future;
    });
    final request = history.fetchMusicServerHistory(libraryId: '3');
    final rejected = expectLater(request, throwsStateError);
    await sent.future;
    history.bindMusicHistoryResource(owned: false);
    response.complete(_page([_entry(1)]));
    await rejected;
  });
}
