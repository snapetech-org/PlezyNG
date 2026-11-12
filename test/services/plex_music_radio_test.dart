import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/services/music/server_music_radio.dart';
import 'package:plezy/services/plex_api_cache.dart';

import '../test_helpers/backend_client_fixtures.dart';

const radioKey = '/library/sections/3/stations/1';
Map<String, dynamic> station({String key = radioKey, String? library = '3'}) => {
  'type': 'playlist',
  'playlistType': 'audio',
  'radio': 1,
  'key': key,
  'title': 'Library Radio',
  'librarySectionID': ?library,
};
Map<String, dynamic> catalog([List<dynamic>? rows]) => {
  'MediaContainer': <String, dynamic>{
    'Hub': <dynamic>[
      <String, dynamic>{
        'context': 'hub.music.stations',
        'Metadata': rows ?? [station()],
      },
    ],
  },
};
Map<String, dynamic> queue([List<dynamic>? tracks]) => {
  'MediaContainer': <String, dynamic>{
    'playQueueID': 7,
    'playQueueVersion': 1,
    'size': tracks?.length ?? 2,
    'playQueueTotalCount': tracks?.length ?? 2,
    'Metadata':
        tracks ??
        [
          {'ratingKey': 'a', 'type': 'track', 'title': 'A'},
          {'ratingKey': 'b', 'type': 'track', 'title': 'B'},
        ],
  },
};
http.Response json(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

void main() {
  late AppDatabase db;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
  });
  tearDown(() => db.close());

  test('station keys are local, bounded and contain no credentials or path escapes', () {
    for (final key in [radioKey, '/library/metadata/12855/station/8bd39616-dbdb-459e-b8da-f46d0b170af4?type=10']) {
      expect(validServerMusicRadioKey(key, '3'), isTrue, reason: key);
    }
    for (final key in [
      '',
      'library/sections/3/stations/1',
      'https://elsewhere/library/sections/3/stations/1',
      '//elsewhere/library/sections/3/stations/1',
      '/library/sections/4/stations/1',
      '$radioKey?X-Plex-Token=secret',
      '$radioKey?type=10&type=10',
      '$radioKey?type=1',
      '$radioKey#fragment',
      '/library/metadata/1/../station/1',
      '/library/metadata/1/%2e%2e/station/1',
      '/library/sections/3/stations/%2fsecret',
      '/library/sections/3/stations/%5csecret',
      '/library/sections/3/stations/%00',
      '/library/sections/3/stations/\n',
      '/library/sections/3/stations/${'x' * 4096}',
    ]) {
      expect(validServerMusicRadioKey(key, '3'), isFalse, reason: key);
    }
  });

  test('hubs request stations and launch the exact issued opaque key as an audio play queue', () async {
    final requests = <http.Request>[];
    final client = testPlexClient(
      serverId: ServerId('srv'),
      handler: (request) async {
        requests.add(request);
        return json(request.method == 'POST' ? queue() : catalog());
      },
    );
    addTearDown(client.close);
    final radios = await client.serverMusicRadios('3');
    expect(radios.single.title, 'Library Radio');
    expect(requests.single.url.path, '/hubs/sections/3');
    expect(requests.single.url.queryParameters['includeStations'], '1');
    expect(requests.single.url.queryParameters['includeMyMixes'], '1');
    expect(requests.single.url.queryParameters['count'], '32');
    expect(() => radios.clear(), throwsUnsupportedError);
    final tracks = await client.serverMusicRadioTracks(radios.single, limit: 1);
    expect(tracks.single.id, 'a');
    expect(tracks.single.libraryId, '3');
    expect(tracks.single.serverId, 'srv');
    expect(() => tracks.clear(), throwsUnsupportedError);
    expect(requests.last.method, 'POST');
    expect(requests.last.url.path, '/playQueues');
    expect(requests.last.url.queryParameters['type'], 'audio');
    expect(requests.last.url.queryParameters['uri'], 'server://srv/com.plexapp.plugins.library$radioKey');
    expect(requests.every((r) => !r.url.path.endsWith('/items')), isTrue);
  });

  test('personalized radio families preserve server labels without a hard-coded context allowlist', () async {
    final body = catalog();
    ((body['MediaContainer'] as Map)['Hub'] as List).add(<String, dynamic>{
      'context': 'hub.music.personalized-family',
      'title': 'Mixes For You',
      'Metadata': [station(key: '/library/metadata/11/station/personal?type=10')],
    });
    final client = testPlexClient(handler: (_) async => json(body));
    addTearDown(client.close);
    final radios = await client.serverMusicRadios('3');
    expect(radios, hasLength(2));
    expect(radios.last.familyId, 'hub.music.personalized-family');
    expect(radios.last.familyTitle, 'Mixes For You');
    expect(ServerMusicRadio.fromJson(radios.last.toJson()).familyTitle, 'Mixes For You');
  });

  test('catalog rejects foreign and nonradio playlists and deduplicates keys', () async {
    final rows = [
      station(),
      station(),
      station(key: '/library/sections/4/stations/1'),
      station(key: '/library/metadata/1/station/1', library: '4'),
      {...station(key: '/library/metadata/2/station/1'), 'playlistType': 'video'},
      {...station(key: '/library/metadata/3/station/1'), 'radio': false},
      {...station(key: '/library/metadata/4/station/1'), 'title': ''},
      {...station(key: '/library/metadata/5/station/1'), 'type': 'track'},
    ];
    final client = testPlexClient(handler: (_) async => json(catalog(rows)));
    addTearDown(client.close);
    expect(await client.serverMusicRadios('3'), hasLength(1));
  });

  test('all explicit containing library identities must match', () async {
    var body = catalog();
    final client = testPlexClient(handler: (_) async => json(body));
    addTearDown(client.close);
    (body['MediaContainer'] as Map)['librarySectionID'] = 4;
    await expectLater(client.serverMusicRadios('3'), throwsFormatException);
    body = catalog();
    ((body['MediaContainer'] as Map)['Hub'] as List).first['librarySectionID'] = 4;
    expect(await client.serverMusicRadios('3'), isEmpty);
  });

  test('empty catalogs stay empty and malformed or oversized catalogs fail', () async {
    Object body = {
      'MediaContainer': {'size': 0},
    };
    final client = testPlexClient(handler: (_) async => json(body));
    addTearDown(client.close);
    expect(await client.serverMusicRadios('3'), isEmpty);
    for (final invalid in [
      {},
      {
        'MediaContainer': {'Hub': {}},
      },
      {
        'MediaContainer': {'Hub': List.filled(65, {})},
      },
      catalog(List.generate(65, (i) => station(key: '/library/sections/3/stations/$i'))),
    ]) {
      body = invalid;
      await expectLater(client.serverMusicRadios('3'), throwsFormatException);
    }
    body = catalog(List.generate(64, (i) => station(key: '/library/sections/3/stations/$i')));
    expect(await client.serverMusicRadios('3'), hasLength(32));
  });

  test('forged, retired, offline, account-changed and closed rows cannot open queues', () async {
    var posts = 0;
    var body = catalog();
    final client = testPlexClient(
      handler: (r) async {
        if (r.method == 'POST') posts++;
        return json(body);
      },
    );
    addTearDown(client.close);
    var issued = (await client.serverMusicRadios('3')).single;
    final forged = ServerMusicRadio(serverId: issued.serverId, libraryId: '3', key: radioKey, title: issued.title);
    await expectLater(client.serverMusicRadioTracks(forged), throwsStateError);
    expect(identical((await client.serverMusicRadios('3')).single, issued), isTrue);
    body = catalog([station(key: '/library/sections/3/stations/2')]);
    await client.serverMusicRadios('3');
    await expectLater(client.serverMusicRadioTracks(issued), throwsStateError);
    issued = (await client.serverMusicRadios('3')).single;
    client.setOfflineMode(true);
    await expectLater(client.serverMusicRadioTracks(issued), throwsStateError);
    client.setOfflineMode(false);
    client.plexAccountId = 'replacement';
    await expectLater(client.serverMusicRadioTracks(issued), throwsStateError);
    issued = (await client.serverMusicRadios('3')).single;
    for (final limit in [0, 501]) {
      await expectLater(client.serverMusicRadioTracks(issued, limit: limit), throwsArgumentError);
    }
    client.close();
    expect(client.serverMusicRadioCurrent(issued), isFalse);
    expect(posts, 0);
  });

  test('out-of-order catalog replies cannot supersede a newer issued generation', () async {
    final replies = <Completer<http.Response>>[];
    final client = testPlexClient(
      handler: (_) {
        final reply = Completer<http.Response>();
        replies.add(reply);
        return reply.future;
      },
    );
    addTearDown(client.close);
    final old = client.serverMusicRadios('3');
    final oldCheck = expectLater(old, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    final fresh = client.serverMusicRadios('3');
    await Future<void>.delayed(Duration.zero);
    replies[1].complete(json(catalog()));
    final issued = (await fresh).single;
    replies[0].complete(json(catalog()));
    await oldCheck;
    expect(client.serverMusicRadioCurrent(issued), isTrue);
  });

  test('account changes during catalog reads reject the late response', () async {
    final reply = Completer<http.Response>();
    final client = testPlexClient(handler: (_) => reply.future);
    addTearDown(client.close);
    final load = client.serverMusicRadios('3');
    final check = expectLater(load, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    client.plexMusicUserIdentifier = 'new-user';
    client.plexAccountId = 'account';
    reply.complete(json(catalog()));
    await check;
  });

  test('account changes during queue creation reject late audio metadata', () async {
    final reply = Completer<http.Response>();
    final client = testPlexClient(handler: (r) async => r.method == 'POST' ? reply.future : json(catalog()));
    addTearDown(client.close);
    final issued = (await client.serverMusicRadios('3')).single;
    final load = client.serverMusicRadioTracks(issued);
    final check = expectLater(load, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    client.plexAccountId = 'replacement';
    reply.complete(json(queue()));
    await check;
  });

  test('authentication changes invalidate an issued station even for the same account', () async {
    final client = testPlexClient(
      serverId: ServerId('srv'),
      handler: (r) async {
        if (r.url.path == '/') {
          return json({
            'MediaContainer': {'machineIdentifier': 'srv'},
          });
        }
        if (r.url.path == '/media/providers') return json({'MediaContainer': {}});
        return json(catalog());
      },
    );
    addTearDown(client.close);
    final issued = (await client.serverMusicRadios('3')).single;
    expect(await client.applyProfileUpdate(newToken: 'replacement', newProfileScopeId: client.profileScopeId), isTrue);
    expect(client.serverMusicRadioCurrent(issued), isFalse);
  });

  test('bad queue windows are rejected as a whole, and a valid empty queue remains empty', () async {
    var body = queue();
    final client = testPlexClient(handler: (r) async => json(r.method == 'POST' ? body : catalog()));
    addTearDown(client.close);
    final issued = (await client.serverMusicRadios('3')).single;
    for (final invalid in [
      {'size': 3},
      {'playQueueTotalCount': -1},
      {'playQueueID': 0},
      {'playQueueVersion': null},
      {'librarySectionID': '4'},
      {
        'Metadata': [null],
      },
      {
        'Metadata': [
          {'ratingKey': 'a', 'title': 'Video', 'type': 'movie'},
        ],
        'size': 1,
        'playQueueTotalCount': 1,
      },
      {
        'Metadata': [
          {'ratingKey': 'a', 'title': 'Foreign', 'type': 'track', 'librarySectionID': '4'},
        ],
        'size': 1,
        'playQueueTotalCount': 1,
      },
      {
        'Metadata': List.filled(501, {'ratingKey': 'a', 'title': 'Track', 'type': 'track'}),
        'size': 501,
        'playQueueTotalCount': 501,
      },
    ]) {
      body = queue();
      (body['MediaContainer'] as Map).addAll(invalid);
      await expectLater(client.serverMusicRadioTracks(issued), throwsA(isA<Exception>()));
    }
    body = queue([]);
    expect(await client.serverMusicRadioTracks(issued), isEmpty);
  });

  test('authorization failures remain errors and do not mint radio rows', () async {
    final client = testPlexClient(handler: (_) async => http.Response('{}', 403));
    addTearDown(client.close);
    await expectLater(client.serverMusicRadios('3'), throwsA(isA<Exception>()));
    await expectLater(client.serverMusicRadios(''), throwsArgumentError);
  });
}
