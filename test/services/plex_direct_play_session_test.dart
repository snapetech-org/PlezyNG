import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_direct_play_identity.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/media_items.dart';

void main() {
  late AppDatabase db;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
  });
  tearDown(() => db.close());

  http.Response metadata() => http.Response(
    jsonEncode({
      'MediaContainer': {
        'Metadata': [
          {
            'ratingKey': '42',
            'type': 'movie',
            'title': 'Two editions',
            'duration': 120000,
            'Media': [
              {
                'id': 10,
                'container': 'mkv',
                'Part': [
                  {'id': 100, 'key': '/library/parts/100/file.mkv', 'exists': false},
                ],
              },
              {
                'id': 20,
                'container': 'mkv',
                'height': 720,
                'bitrate': 1000,
                'Part': [
                  {'id': 200, 'key': '/library/parts/200/file.mkv', 'duration': 60000, 'Stream': []},
                  {'id': 201, 'key': '/library/parts/201/file.mkv', 'duration': 60000, 'Stream': []},
                ],
              },
            ],
          },
        ],
      },
    }),
    200,
    headers: {'content-type': 'application/json'},
  );

  PlaybackInitializationOptions options({TranscodeQualityPreset quality = TranscodeQualityPreset.original}) =>
      PlaybackInitializationOptions(
        metadata: testMediaItem(id: '42'),
        selectedMediaIndex: 1,
        selectedMediaSourceId: '20',
        startPosition: const Duration(seconds: 75),
        sessionIdentifier: 'playback-session',
        transcodeSessionId: 'transcode-session',
        qualityPreset: quality,
      );

  test('registration precedes the selected later part with matching stream identity', () async {
    final decision = Completer<http.Response>();
    final received = Completer<http.Request>();
    final client = testPlexClient(
      handler: (request) async {
        if (request.url.path == '/library/metadata/42') return metadata();
        received.complete(request);
        return decision.future;
      },
    );
    addTearDown(client.close);
    var ready = false;
    final pending = client.getPlaybackInitialization(options()).then((value) {
      ready = true;
      return value;
    });
    final request = await received.future;
    expect(ready, isFalse);
    expect(request.url.path, '/video/:/transcode/universal/decision');
    expect(request.url.queryParameters, containsPair('mediaIndex', '1'));
    expect(request.url.queryParameters, containsPair('partIndex', '1'));
    expect(request.url.queryParameters, containsPair('directPlay', '1'));
    expect(request.headers['X-Plex-Session-Identifier'], 'playback-session');
    // A server-supplied URL must not replace the chosen file.
    decision.complete(http.Response('{"MediaContainer":{"url":"https://wrong.test/video"}}', 200));
    final result = await pending;
    final url = Uri.parse(result.videoUrl!);
    expect(url.path, '/library/parts/201/file.mkv');
    expect(result.playSessionId, 'playback-session');
    expect(url.queryParameters['X-Plex-Session-Identifier'], result.playSessionId);
    expect(url.queryParameters['X-Plex-Client-Identifier'], request.url.queryParameters['X-Plex-Client-Identifier']);
    expect(result.isTranscoding, isFalse);
  });

  test('registration refusal retains the file without retrying other endpoints', () async {
    var decisions = 0;
    final client = testPlexClient(
      handler: (request) async {
        if (request.url.path == '/library/metadata/42') return metadata();
        decisions++;
        return http.Response('', 503);
      },
    );
    addTearDown(client.close);
    expect((await client.getPlaybackInitialization(options())).videoUrl, contains('/library/parts/201/'));
    expect(decisions, 1);
  });

  test('a hung decision is bounded and the file remains playable', () async {
    final client = testPlexClient(
      handler: (request) async {
        if (request.url.path == '/library/metadata/42') return metadata();
        return Completer<http.Response>().future;
      },
    );
    addTearDown(client.close);
    expect((await client.getPlaybackInitialization(options())).videoUrl, contains('/library/parts/201/'));
  });

  test('failed transcoding registers the selected file when falling back', () async {
    final decisions = <Uri>[];
    final client = testPlexClient(
      handler: (request) async {
        if (request.url.path == '/library/metadata/42') return metadata();
        decisions.add(request.url);
        return http.Response(
          '{"MediaContainer":{"transcodeDecisionCode":2000}}',
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
    addTearDown(client.close);
    final result = await client.getPlaybackInitialization(options(quality: TranscodeQualityPreset.p480_1_5mbps));
    expect(result.fallbackReason, isNotNull);
    expect(result.isTranscoding, isFalse);
    expect(result.videoUrl, contains('/library/parts/201/'));
    expect(decisions.last.queryParameters, containsPair('protocol', 'http'));
    expect(decisions.last.queryParameters, containsPair('mediaIndex', '1'));
    expect(decisions.last.queryParameters, containsPair('partIndex', '1'));
    expect(decisions.last.queryParameters, containsPair('X-Plex-Session-Identifier', result.playSessionId));
  });

  test('cancellation does not open a file after the client closes', () async {
    final client = testPlexClient(
      handler: (request) async {
        if (request.url.path == '/library/metadata/42') return metadata();
        throw MediaServerHttpException(type: MediaServerHttpErrorType.cancelled, message: 'cancelled');
      },
    );
    addTearDown(client.close);
    await expectLater(
      client.getPlaybackInitialization(options()),
      throwsA(isA<PlaybackException>().having((e) => e.reason, 'reason', PlaybackFailureReason.cancelled)),
    );
  });

  test('external handoff resolves by version id and retains the registration identity', () async {
    Uri? decision;
    final client = testPlexClient(
      handler: (request) async {
        if (request.url.path == '/library/metadata/42') return metadata();
        decision = request.url;
        return http.Response('{}', 200);
      },
    );
    addTearDown(client.close);
    final target = await client.resolveExternalPlayback(
      testMediaItem(id: '42'),
      mediaIndex: 0,
      mediaSourceId: '20',
      position: const Duration(seconds: 75),
    );
    expect(Uri.parse(target!.url).path, '/library/parts/201/file.mkv');
    expect(target.playSessionId, isNotEmpty);
    expect(decision!.queryParameters['X-Plex-Session-Identifier'], target.playSessionId);
    expect(Uri.parse(target.url).queryParameters['X-Plex-Session-Identifier'], target.playSessionId);
  });

  test('music does not register a video decision', () async {
    final paths = <String>[];
    final client = testPlexClient(
      handler: (request) async {
        paths.add(request.url.path);
        return metadata();
      },
    );
    addTearDown(client.close);
    await client.getPlaybackInitialization(
      PlaybackInitializationOptions(
        metadata: testMediaItem(id: '42', kind: MediaKind.track),
        selectedMediaIndex: 1,
        sessionIdentifier: 'music',
      ),
    );
    expect(paths, ['/library/metadata/42']);
  });

  test('identity replacement preserves opaque query bytes, duplicate keys and fragment', () {
    final url = plexDirectPlayIdentity(
      'https://host/file?sig=a%2fb+z&tag=1&tag=2&X-Plex-Session-Identifier=old&x%2dplex%2dclient%2didentifier=old#part',
      clientId: 'our client',
      sessionId: 'session&new',
    );
    expect(
      url,
      'https://host/file?sig=a%2fb+z&tag=1&tag=2&X-Plex-Client-Identifier=our%20client&X-Plex-Session-Identifier=session%26new#part',
    );
  });
}
