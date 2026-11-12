import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_playlist.dart';
import 'package:plezy/screens/playlist/playlist_share_dialog.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_auth_service.dart';
import 'package:plezy/services/plex_playlist_sharing.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
  });

  for (final retired in [false, true]) {
    testWidgets(
      retired
          ? 'retired recipient decision cannot send a grant'
          : 'explicit recipient confirmation sends once and closes only after acknowledgement',
      (tester) async {
        var current = true, requests = 0;
        final pending = Completer<http.Response>();
        final client = testPlexClient(
          serverId: ServerId('s'),
          config: testPlexConfig(machineIdentifier: 'machine'),
          handler: (_) async => jsonResponse({
            'MediaContainer': {
              'Metadata': [
                {'ratingKey': '123', 'title': 'Music', 'playlistType': 'audio', 'smart': false},
              ],
            },
          }),
        );
        client.plexAccountToken = 'account-token';
        final auth = PlexAuthService.forTesting(
          http: MediaServerHttpClient(
            client: MockClient((_) {
              requests++;
              return pending.future;
            }),
          ),
        );
        addTearDown(client.close);
        addTearDown(auth.dispose);
        final sharing = PlexPlaylistSharing(
          client: client,
          auth: auth,
          playlist: const MediaPlaylist(
            id: '123',
            backend: MediaBackend.plex,
            title: 'Music',
            playlistType: 'audio',
            serverId: 's',
          ),
          isCurrent: () => current,
        );
        final draft = await sharing.prepare();
        bool? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showDialog<bool>(
                      context: context,
                      builder: (_) => PlaylistShareDialog(draft: draft, sharing: sharing),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(requests, 0);
        await tester.tap(find.byKey(const ValueKey('playlist_share_confirm')));
        await tester.pumpAndSettle();
        expect(requests, 0);
        await tester.enterText(find.byKey(const ValueKey('playlist_share_recipient')), 'friend@example.com');
        if (retired) current = false;
        await tester.tap(find.byKey(const ValueKey('playlist_share_confirm')));
        await tester.pump();
        if (retired) {
          expect(requests, 0);
          expect(find.text(t.musicTools.playlistSharingFailed), findsOneWidget);
          expect(result, isNull);
        } else {
          expect(requests, 1);
          expect(result, isNull);
          await tester.tap(find.byKey(const ValueKey('playlist_share_confirm')));
          await tester.pump();
          expect(requests, 1);
          pending.complete(
            jsonResponse([
              {'sharedSourceId': 42},
            ]),
          );
          await tester.pumpAndSettle();
          expect(result, isTrue);
          expect(find.byType(PlaylistShareDialog), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
