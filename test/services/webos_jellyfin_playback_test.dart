import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/jellyfin_client.dart';
import '../test_helpers/backend_client_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('LG native server capabilities', () {
    for (final emby in [false, true]) {
      for (final convert in [false, true]) {
        test('${emby ? 'Emby' : 'Jellyfin'} conversion=$convert preserves initial audio and HEVC', () async {
          late Map<String, dynamic> body;
          final client = JellyfinClient.forTesting(
            connection: emby ? testEmbyConnection() : testJellyfinConnection(),
            httpClient: MockClient((request) async {
              body = jsonDecode(request.body) as Map<String, dynamic>;
              return http.Response(
                jsonEncode({'MediaSources': []}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          );
          addTearDown(client.close);
          await client.getPlaybackInfo('movie', allowAudioStreamCopy: convert ? false : null);
          final profile = body['DeviceProfile'] as Map<String, dynamic>;
          final direct = (profile['DirectPlayProfiles'] as List).cast<Map<String, dynamic>>().firstWhere(
            (p) => p['Type'] == 'Video',
          );
          expect(direct['VideoCodec'], contains('hevc'));
          if (convert) {
            expect(direct['AudioCodec'], contains('aac'));
            expect(direct['AudioCodec'], isNot(contains('dts')));
            expect(direct['AudioCodec'], isNot(contains('truehd')));
          } else {
            expect(direct.containsKey('AudioCodec'), isFalse);
          }
          final transcodes = (profile['TranscodingProfiles'] as List).cast<Map<String, dynamic>>().where(
            (p) => p['Type'] == 'Video',
          );
          for (final transcode in transcodes) {
            expect(transcode['AudioCodec'], contains('aac'));
            expect(transcode['AudioCodec'], convert ? isNot(contains('dts')) : contains('dts'));
            if (convert) {
              expect(transcode['AudioCodec'], isNot(contains('truehd')));
            }
          }
          final subtitles = (profile['SubtitleProfiles'] as List).cast<Map<String, dynamic>>();
          expect(subtitles.map((p) => p['Format']), isNot(contains('pgssub')));
          expect(subtitles.map((p) => p['Format']), contains('srt'));
        });
      }
    }
  }, skip: !const bool.fromEnvironment('PLEZY_WEBOS'));
}
