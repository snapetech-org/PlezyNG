import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/plex_api_cache.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/media_items.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('LG native Plex negotiation', () {
    late AppDatabase db;
    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      PlexApiCache.initialize(db);
    });
    tearDown(() => db.close());

    for (final scenario in [
      (
        decisionWorks: true,
        selectedAudio: 301,
        conversion: true,
        label: 'rejected DTS converts while preserving HEVC/HDR',
      ),
      (
        decisionWorks: false,
        selectedAudio: 301,
        conversion: true,
        label: 'failed conversion cannot fall back to DTS original',
      ),
      (
        decisionWorks: true,
        selectedAudio: 302,
        conversion: false,
        label: 'explicit compatible AAC track remains direct play',
      ),
      (
        decisionWorks: true,
        selectedAudio: 301,
        conversion: false,
        label: 'DTS initial attempt preserves direct play and passthrough',
      ),
    ]) {
      test(scenario.label, () async {
        final decisions = <Uri>[];
        final client = testPlexClient(
          serverId: ServerId('tv-server'),
          handler: (request) async {
            if (request.url.path == '/library/metadata/42') {
              return http.Response(
                jsonEncode({
                  'MediaContainer': {
                    'Metadata': [
                      {
                        'ratingKey': '42',
                        'type': 'movie',
                        'title': 'Movie',
                        'Media': [
                          {
                            'id': 7,
                            'container': 'mkv',
                            'videoCodec': 'hevc',
                            'height': 2160,
                            'Part': [
                              {
                                'id': 99,
                                'key': '/library/parts/99/file.mkv',
                                'Stream': [
                                  {'streamType': 1, 'id': 300, 'codec': 'hevc', 'colorTrc': 'smpte2084'},
                                  {'streamType': 2, 'id': 301, 'codec': 'dca', 'channels': 8, 'selected': true},
                                  {'streamType': 2, 'id': 302, 'codec': 'aac', 'channels': 2},
                                ],
                              },
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
            }
            if (request.url.path.endsWith('/decision')) {
              decisions.add(request.url);
              if (!scenario.decisionWorks) return http.Response('unavailable', 500);
              return http.Response(
                jsonEncode({
                  'MediaContainer': {
                    'generalDecisionCode': 1001,
                    'transcodeDecisionCode': 1001,
                    'Metadata': [
                      {
                        'Media': [
                          {'container': 'mpegts', 'protocol': 'hls', 'selected': true},
                        ],
                      },
                    ],
                  },
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response('unexpected request', 404);
          },
        );
        addTearDown(client.close);
        final result = client.getPlaybackInitialization(
          PlaybackInitializationOptions(
            metadata: testMediaItem(id: '42', backend: MediaBackend.plex, kind: MediaKind.movie, serverId: 'tv-server'),
            selectedMediaIndex: 0,
            selectedAudioStreamId: scenario.selectedAudio,
            forceAudioConversion: scenario.conversion,
            qualityPreset: TranscodeQualityPreset.original,
            sessionIdentifier: 'session',
            transcodeSessionId: 'transcode',
          ),
        );
        if (!scenario.conversion) {
          expect((await result).isTranscoding, isFalse);
          expect(decisions.single.queryParameters['directPlay'], '1');
          expect(decisions.single.queryParameters.containsKey('directStreamAudio'), isFalse);
          return;
        }
        if (scenario.decisionWorks) {
          expect((await result).isTranscoding, isTrue);
        } else {
          await expectLater(result, throwsA(isA<PlaybackException>()));
        }
        expect(decisions, isNotEmpty);
        final params = decisions.first.queryParameters;
        expect(params['directPlay'], '0');
        expect(params['directStream'], '1');
        expect(params['directStreamAudio'], '0');
        expect(params.containsKey('videoResolution'), isFalse);
        final profile = params['X-Plex-Client-Profile-Extra']!;
        expect(profile, contains('hevc'));
        expect(params['audioStreamID'], '301');
      });
    }
  }, skip: !const bool.fromEnvironment('PLEZY_WEBOS'));
}
