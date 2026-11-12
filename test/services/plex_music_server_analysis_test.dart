import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_client.dart';
import 'package:plezy/utils/media_server_http_client.dart';

import '../test_helpers/backend_client_fixtures.dart';

http.Response _json(Object data, [int status = 200]) =>
    http.Response(jsonEncode(data), status, headers: {'content-type': 'application/json'});
http.Response _tasks([List<Object>? rows]) => _json({
  'ButlerTasks': {
    'ButlerTask':
        rows ??
        [
          {'name': 'MusicAnalysis', 'enabled': false},
          {'name': 'LoudnessAnalysis', 'enabled': true},
          {'name': 'OptimizeDatabase', 'enabled': true},
        ],
  },
});
http.Response _activities([List<Object>? rows]) => _json({
  'MediaContainer': {
    'Activity':
        rows ??
        [
          {
            'uuid': 'analysis',
            'title': 'Sonic Analysis',
            'subtitle': 'Album',
            'type': 'server.provided',
            'progress': -1,
          },
        ],
  },
});

void main() {
  late AppDatabase database;
  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(database);
  });
  tearDown(() => database.close());

  PlexClient client(Future<http.Response> Function(http.Request) handler, {bool owned = true}) {
    final client = testPlexClient(serverId: ServerId('server'), handler: handler)
      ..plexAccountId = 'plex.owner'
      ..plexMusicUserIdentifier = 'owner'
      ..bindMusicHistoryResource(owned: owned);
    addTearDown(client.close);
    return client;
  }

  test('reads advertised music tasks and server activities without guessing an activity type', () async {
    final calls = <String>[];
    final server = client((request) async {
      calls.add('${request.method} ${request.url.path}');
      expect(request.headers['x-plex-token'], 'token');
      return request.url.path == '/butler' ? _tasks() : _activities();
    });
    final snapshot = await server.readMusicServerAnalysis(current: () => true);
    expect(snapshot.tasks, {PlexMusicServerTask.sonic, PlexMusicServerTask.loudness});
    expect(snapshot.activities.single.title, 'Sonic Analysis');
    expect(snapshot.activities.single.progress, -1);
    expect(calls, ['GET /butler', 'GET /activities']);
    expect(() => snapshot.tasks.clear(), throwsUnsupportedError);
    expect(() => snapshot.activities.clear(), throwsUnsupportedError);
  });

  test('named start and stop preflight independently without changing scheduling or other tasks', () async {
    final calls = <String>[];
    var startStatus = 200;
    final server = client((request) async {
      calls.add('${request.method} ${request.url.path}');
      expect(request.url.query, isEmpty);
      expect(request.body, isEmpty);
      if (request.url.path == '/butler') return _tasks();
      return http.Response('', request.method == 'POST' ? startStatus : 200);
    });
    expect(
      await server.changeMusicServerAnalysis(PlexMusicServerTask.sonic, start: true, current: () => true),
      PlexMusicServerTaskRequest.started,
    );
    startStatus = 202;
    expect(
      await server.changeMusicServerAnalysis(PlexMusicServerTask.loudness, start: true, current: () => true),
      PlexMusicServerTaskRequest.alreadyRunning,
    );
    expect(
      await server.changeMusicServerAnalysis(PlexMusicServerTask.sonic, start: false, current: () => true),
      PlexMusicServerTaskRequest.stopped,
    );
    expect(calls, [
      'GET /butler',
      'POST /butler/MusicAnalysis',
      'GET /butler',
      'POST /butler/LoudnessAnalysis',
      'GET /butler',
      'DELETE /butler/MusicAnalysis',
    ]);
  });

  test('a task absent from fresh server advertisement cannot be started', () async {
    var calls = 0;
    final server = client((request) async {
      calls++;
      expect(request.method, 'GET');
      return _tasks([
        {'name': 'LoudnessAnalysis'},
      ]);
    });
    await expectLater(
      server.changeMusicServerAnalysis(PlexMusicServerTask.sonic, start: true, current: () => true),
      throwsUnsupportedError,
    );
    expect(calls, 1);
  });

  test('unverified owner and retired caller perform no requests', () async {
    var calls = 0;
    final server = client((_) async {
      calls++;
      return _tasks();
    }, owned: false);
    await expectLater(server.readMusicServerAnalysis(current: () => true), throwsStateError);
    await expectLater(
      server.changeMusicServerAnalysis(PlexMusicServerTask.sonic, start: true, current: () => true),
      throwsStateError,
    );
    server.bindMusicHistoryResource(owned: true);
    await expectLater(server.readMusicServerAnalysis(current: () => false), throwsStateError);
    expect(calls, 0);
  });

  for (final operation in ['read', 'start', 'stop']) {
    for (final retirement in ['caller', 'owner', 'route']) {
      test('$retirement retirement during task preflight prevents late $operation', () async {
        final entered = Completer<void>(), response = Completer<http.Response>();
        var calls = 0, current = true;
        final server = client((request) {
          calls++;
          expect(request.method, 'GET');
          expect(request.url.path, '/butler');
          entered.complete();
          return response.future;
        });
        final Future<Object> pending = operation == 'read'
            ? server.readMusicServerAnalysis(current: () => current)
            : server.changeMusicServerAnalysis(
                PlexMusicServerTask.sonic,
                start: operation == 'start',
                current: () => current,
              );
        await entered.future;
        switch (retirement) {
          case 'caller':
            current = false;
          case 'owner':
            server.bindMusicHistoryResource(owned: false);
          case 'route':
            server.config = server.config.copyWith(baseUrl: 'http://replacement.invalid');
        }
        final failure = expectLater(pending, throwsStateError);
        response.complete(_tasks());
        await failure;
        expect(calls, 1);
      });
    }
  }

  test('an account change while activities load cannot expose the previous snapshot', () async {
    final entered = Completer<void>(), response = Completer<http.Response>();
    final server = client((request) {
      if (request.url.path == '/butler') return Future.value(_tasks());
      entered.complete();
      return response.future;
    });
    final pending = server.readMusicServerAnalysis(current: () => true);
    await entered.future;
    server.plexMusicUserIdentifier = 'different';
    final failure = expectLater(pending, throwsStateError);
    response.complete(_activities());
    await failure;
  });

  for (final malformed in [
    _json({'ButlerTasks': {}}),
    _tasks([
      {'name': 'MusicAnalysis'},
      {'name': 'MusicAnalysis'},
    ]),
    _tasks(List.filled(257, {'name': 'unknown'})),
  ]) {
    test('malformed task advertisement fails without starting anything: ${malformed.body.length}', () async {
      var calls = 0;
      final server = client((request) async {
        calls++;
        return malformed;
      });
      await expectLater(
        server.changeMusicServerAnalysis(PlexMusicServerTask.sonic, start: true, current: () => true),
        throwsFormatException,
      );
      expect(calls, 1);
    });
  }

  for (final response in [
    http.Response('{}', 403),
    _json({
      'MediaContainer': {'Activity': 'invalid'},
    }),
    _activities([
      {'uuid': '', 'title': 'Invalid'},
    ]),
    _activities([
      {'uuid': 'a', 'title': 'A'},
      {'uuid': 'a', 'title': 'Duplicate'},
    ]),
  ]) {
    test('activity refusal or corruption is not reported as an empty completed set: ${response.body.length}', () async {
      final server = client((request) async => request.url.path == '/butler' ? _tasks() : response);
      await expectLater(server.readMusicServerAnalysis(current: () => true), throwsA(anything));
    });
  }

  for (final invalid in ['NaN', 'Infinity', -2, -.5, 101, <String, Object>{}]) {
    test('invalid server activity progress is rejected: $invalid', () async {
      final server = client(
        (request) async => request.url.path == '/butler'
            ? _tasks()
            : _activities([
                {'uuid': 'job', 'progress': invalid},
              ]),
      );
      await expectLater(server.readMusicServerAnalysis(current: () => true), throwsFormatException);
    });
  }

  test('fractional progress is retained as a percentage and missing progress is indeterminate', () async {
    final server = client(
      (request) async => request.url.path == '/butler'
          ? _tasks()
          : _activities([
              {'uuid': 'fraction', 'progress': '53.5'},
              {'uuid': 'missing'},
            ]),
    );
    final snapshot = await server.readMusicServerAnalysis(current: () => true);
    expect(snapshot.activities.map((activity) => activity.progress), [53, -1]);
  });

  test('failed writes do not poison serialization and a queued stop waits for the first request', () async {
    final entered = Completer<void>(), response = Completer<http.Response>();
    final calls = <String>[];
    final server = client((request) async {
      calls.add('${request.method} ${request.url.path}');
      if (request.method == 'GET') return _tasks();
      if (request.method == 'POST') {
        entered.complete();
        return response.future;
      }
      return http.Response('', 200);
    });
    final first = server.changeMusicServerAnalysis(PlexMusicServerTask.sonic, start: true, current: () => true);
    final failure = expectLater(first, throwsA(anything));
    await entered.future;
    final second = server.changeMusicServerAnalysis(PlexMusicServerTask.sonic, start: false, current: () => true);
    await pumpEventQueue();
    expect(calls, ['GET /butler', 'POST /butler/MusicAnalysis']);
    response.complete(http.Response('{}', 500));
    await failure;
    expect(await second, PlexMusicServerTaskRequest.stopped);
    expect(calls.last, 'DELETE /butler/MusicAnalysis');
  });

  test('queued writes retain their original account before serialization', () async {
    final entered = Completer<void>(), pending = Completer<http.Response>();
    final calls = <String>[];
    final server = client((request) async {
      calls.add('$request');
      if (request.method == 'GET') return _tasks();
      entered.complete();
      return pending.future;
    });
    final first = server.changeMusicServerAnalysis(PlexMusicServerTask.sonic, start: true, current: () => true);
    await entered.future;
    final next = server.changeMusicServerAnalysis(PlexMusicServerTask.sonic, start: false, current: () => true);
    server.plexMusicUserIdentifier = 'replacement';
    final firstFailure = expectLater(first, throwsStateError);
    final nextFailure = expectLater(next, throwsStateError);
    pending.complete(http.Response('', 200));
    await Future.wait([firstFailure, nextFailure]);
    expect(calls.length, 2);
    expect(calls.where((call) => call.startsWith('DELETE')), isEmpty);
  });

  test('aborted polling performs no network requests', () async {
    var calls = 0;
    final server = client((_) async {
      calls++;
      return _tasks();
    });
    final abort = AbortController()..abort();
    await expectLater(server.readMusicServerAnalysis(current: () => true, abort: abort), throwsA(anything));
    expect(calls, 0);
  });
}
