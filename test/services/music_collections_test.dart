import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/plex_api_cache.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';
import '../test_helpers/media_items.dart';

MediaItem _member({
  String id = 'seed',
  MediaKind kind = MediaKind.album,
  String library = '1',
  String server = 's',
  MediaBackend backend = MediaBackend.plex,
}) => testMediaItem(id: id, kind: kind, libraryId: library, serverId: server, backend: backend);
http.Response _target(Map<String, Object?> changes) => jsonResponse({
  'MediaContainer': {
    'Metadata': [
      {
        'ratingKey': 'collection',
        'type': 'collection',
        'subtype': 'album',
        'librarySectionID': 1,
        'smart': false,
        ...changes,
      },
    ],
  },
});
http.Response _identity() => jsonResponse({
  'MediaContainer': {'machineIdentifier': 'machine'},
});
http.Response _created() => jsonResponse({
  'MediaContainer': {
    'Metadata': [
      {'ratingKey': 'new'},
    ],
  },
});

void main() {
  setUp(() {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(database);
    addTearDown(database.close);
  });

  for (final kind in [MediaKind.artist, MediaKind.album]) {
    test('create $kind collection sends its actual member type', () async {
      final writes = <http.Request>[];
      final client = testPlexClient(
        serverId: ServerId('s'),
        config: testPlexConfig(machineIdentifier: 'machine'),
        handler: (request) async {
          writes.add(request);
          return _created();
        },
      );
      addTearDown(client.close);
      expect(
        await client.createCollection(
          libraryId: '1',
          title: 'Collection',
          items: [_member(kind: kind)],
          itemKind: kind,
          isCurrent: () => true,
        ),
        'new',
      );
      final request = writes.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/library/collections');
      expect(request.url.queryParameters['type'], kind == MediaKind.artist ? '8' : '9');
      expect(request.url.queryParameters['sectionId'], '1');
      expect(request.url.queryParameters['uri'], 'server://machine/com.plexapp.plugins.library/library/metadata/seed');
    });
  }

  test('unsupported and foreign collection seeds never issue a request', () async {
    var requests = 0;
    final client = testPlexClient(
      serverId: ServerId('s'),
      handler: (_) async {
        requests++;
        return _created();
      },
    );
    addTearDown(client.close);
    for (final item in [
      _member(kind: MediaKind.track),
      _member(library: '2'),
      _member(server: 'other'),
      _member(backend: MediaBackend.jellyfin),
    ]) {
      await expectLater(
        client.createCollection(libraryId: '1', title: 'Collection', items: [item]),
        throwsArgumentError,
      );
    }
    await expectLater(
      client.createCollection(
        libraryId: '1',
        title: 'Collection',
        items: [
          _member(),
          _member(kind: MediaKind.artist),
        ],
      ),
      throwsArgumentError,
    );
    expect(requests, 0);
  });

  test('regular album membership verifies collection type, library and non-smart status', () async {
    final requests = <http.Request>[];
    final client = testPlexClient(
      serverId: ServerId('s'),
      config: testPlexConfig(machineIdentifier: 'machine'),
      handler: (request) async {
        requests.add(request);
        return request.method == 'GET' ? _target({}) : http.Response('', 200);
      },
    );
    addTearDown(client.close);
    expect(await client.addToCollection(collectionId: 'collection', items: [_member()], isCurrent: () => true), isTrue);
    expect(requests.map((r) => r.method), ['GET', 'PUT']);
    expect(requests.last.url.path, '/library/collections/collection/items');
    expect(requests.last.url.queryParameters['uri'], endsWith('/library/metadata/seed'));
  });

  test('incompatible, foreign, missing and smart music collections cannot accept members', () async {
    for (final changes in <Map<String, Object?>>[
      {'subtype': 'artist'},
      {'smart': true},
      {'smart': null},
      {'ratingKey': 'other'},
      {'librarySectionID': 2},
      {'librarySectionID': null},
      {'type': 'album'},
    ]) {
      var writes = 0;
      final client = testPlexClient(
        serverId: ServerId('s'),
        config: testPlexConfig(machineIdentifier: 'machine'),
        handler: (request) async {
          if (request.method != 'GET') writes++;
          return _target(changes);
        },
      );
      await expectLater(client.addToCollection(collectionId: 'collection', items: [_member()]), throwsStateError);
      expect(writes, 0);
      client.close();
    }
  });

  for (final creating in [false, true]) {
    test('create=$creating scope revoked during URI discovery cannot write', () async {
      final pending = Completer<http.Response>(), started = Completer<void>();
      var current = true, writes = 0;
      final client = testPlexClient(
        serverId: ServerId('s'),
        handler: (request) async {
          if (request.url.path == '/library/metadata/collection') return _target({});
          if (request.method == 'GET') {
            started.complete();
            return pending.future;
          }
          writes++;
          return _created();
        },
      );
      addTearDown(client.close);
      final operation = creating
          ? client.createCollection(libraryId: '1', title: 'Collection', items: [_member()], isCurrent: () => current)
          : client.addToCollection(collectionId: 'collection', items: [_member()], isCurrent: () => current);
      final rejected = expectLater(operation, throwsStateError);
      await started.future;
      current = false;
      pending.complete(_identity());
      await rejected;
      expect(writes, 0);
    });
  }

  test('target preflight retires before URI lookup when its scope changes', () async {
    final pending = Completer<http.Response>(), started = Completer<void>();
    var current = true;
    final paths = <String>[];
    final client = testPlexClient(
      serverId: ServerId('s'),
      handler: (request) async {
        paths.add(request.url.path);
        started.complete();
        return pending.future;
      },
    );
    addTearDown(client.close);
    final operation = client.addToCollection(collectionId: 'collection', items: [_member()], isCurrent: () => current);
    final rejected = expectLater(operation, throwsStateError);
    await started.future;
    current = false;
    pending.complete(_target({}));
    await rejected;
    expect(paths, ['/library/metadata/collection']);
  });

  test('pending URI discovery freezes the original occurrence list', () async {
    final pending = Completer<http.Response>(), started = Completer<void>();
    http.Request? written;
    final client = testPlexClient(
      serverId: ServerId('s'),
      handler: (request) async {
        if (request.method == 'GET') {
          started.complete();
          return pending.future;
        }
        written = request;
        return _created();
      },
    );
    addTearDown(client.close);
    final items = [_member()];
    final operation = client.createCollection(libraryId: '1', title: 'Collection', items: items);
    await started.future;
    items.add(_member(id: 'replacement'));
    pending.complete(_identity());
    expect(await operation, 'new');
    expect(written!.url.queryParameters['uri'], endsWith('/library/metadata/seed'));
  });
}
