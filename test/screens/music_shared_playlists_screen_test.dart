import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/music/music_shared_playlists_screen.dart';
import 'package:plezy/screens/playlist/playlist_detail_screen.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_auth_service.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:provider/provider.dart';
import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';
import '../test_helpers/multi_server_fixtures.dart';

class _Profile extends ChangeNotifier implements ActiveProfileProvider {
  @override
  Profile active = Profile.local(id: 'p', displayName: 'Listener', createdAt: DateTime.utc(2024));
  @override
  String get activeId => active.id;
  @override
  bool isBinding = false;
  @override
  bool lastBindingSucceeded = true;
  @override
  int identityMutationGeneration = 1;
  void retire() {
    isBinding = true;
    identityMutationGeneration++;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Object _sources(int count) => [
  {
    'id': 42,
    'status': 'accepted',
    'owner': {'id': 7, 'username': 'Owner'},
    'sharedItems': [
      for (var i = 1; i <= count; i++)
        {'id': 100 + i, 'uri': 'server://machine/com.plexapp.plugins.library/playlists/$i/items'},
    ],
  },
];

void main() {
  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
  });

  Future<_Profile> pump(
    WidgetTester tester,
    Future<http.Response> Function(http.Request) cloud, {
    bool managed = false,
    double textScale = 1,
  }) async {
    final profile = _Profile();
    if (managed) profile.active = Profile.plexHome(id: 'p', displayName: 'Child', createdAt: DateTime.utc(2024));
    final client = testPlexClient(
      serverId: ServerId('s'),
      config: testPlexConfig(machineIdentifier: 'machine'),
      handler: (request) async {
        final id = request.url.pathSegments.last;
        return jsonResponse({
          'MediaContainer': {
            'Metadata': [
              {'ratingKey': id, 'title': 'Playlist $id', 'playlistType': 'audio', 'smart': false},
            ],
          },
        });
      },
    );
    client.plexAccountToken = 'cloud-token';
    final servers = testMultiServer(clients: [client]);
    addTearDown(profile.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ActiveProfileProvider>.value(value: profile),
          ChangeNotifierProvider<MultiServerProvider>.value(value: servers.provider),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: MusicSharedPlaylistsScreen(
            authFactory: () async => PlexAuthService.forTesting(http: MediaServerHttpClient(client: MockClient(cloud))),
          ),
        ),
      ),
    );
    return profile;
  }

  testWidgets('received music browses raw pages and explicitly loads later entries', (tester) async {
    await pump(tester, (_) async => jsonResponse(_sources(26)));
    await tester.pumpAndSettle();
    expect(find.text('Playlist 1'), findsOneWidget);
    expect(find.text('Playlist 26'), findsNothing);
    await tester.scrollUntilVisible(find.text(t.fileSources.loadMore), 400);
    await tester.tap(find.text(t.fileSources.loadMore));
    await tester.pumpAndSettle();
    expect(find.text('Playlist 26'), findsOneWidget);
    expect(find.text(t.fileSources.loadMore), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a revoked browse entry cannot open playlist detail', (tester) async {
    var calls = 0;
    await pump(tester, (_) async => jsonResponse(++calls == 1 ? _sources(1) : []));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Playlist 1'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(PlaylistDetailScreen), findsNothing);
    expect(find.text(t.musicExperience.error), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('managed profiles cannot read the owner cloud sharing account', (tester) async {
    var calls = 0;
    await pump(tester, (_) async {
      calls++;
      return jsonResponse(_sources(1));
    }, managed: true);
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('Playlist 1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('binding retirement rejects an in-flight incoming grant list', (tester) async {
    final pending = Completer<http.Response>();
    final profile = await pump(tester, (_) => pending.future);
    await tester.pump();
    profile.retire();
    await tester.pump();
    pending.complete(jsonResponse(_sources(1)));
    await tester.pumpAndSettle();
    expect(find.text('Playlist 1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shared playlist browse fits 320px and large text', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pump(tester, (_) async => jsonResponse(_sources(1)), textScale: 2);
    await tester.pumpAndSettle();
    expect(find.text('Playlist 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final accept in [true, false]) {
    testWidgets('whole invitation $accept requires confirmation and refreshes accepted browse', (tester) async {
      var pending = true;
      final writes = <http.Request>[];
      await pump(tester, (request) async {
        if (request.url.path == '/api/v2/shared_sources/invites/received/pending') {
          return jsonResponse([
            if (pending)
              {
                'id': 42,
                'status': 'pending',
                'owner': {'id': 7, 'username': 'Inviter'},
                'invited': {'id': 8},
              },
          ]);
        }
        if (request.method != 'GET') {
          writes.add(request);
          pending = false;
          return http.Response('', 204);
        }
        return jsonResponse([]);
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(t.musicTools.sharingInvitationsTitle));
      await tester.pumpAndSettle();
      expect(find.text('Inviter'), findsOneWidget);
      final action = accept ? t.musicTools.sharingInvitationAccept : t.musicTools.sharingInvitationReject;
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(find.text(t.musicTools.sharingInvitationHint), findsNWidgets(2));
      await tester.tap(find.text(t.common.cancel));
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action).last);
      await tester.pumpAndSettle();
      expect(writes, hasLength(1));
      expect(writes.single.method, accept ? 'POST' : 'DELETE');
      expect(writes.single.url.path, '/api/v2/shared_sources/42${accept ? '/accept' : ''}');
      expect(find.text(t.musicTools.noSharingInvitations), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('profile retirement in invitation confirmation sends no decision', (tester) async {
    var writes = 0;
    final profile = await pump(tester, (request) async {
      if (request.method != 'GET') {
        writes++;
        return http.Response('', 204);
      }
      return jsonResponse(
        request.url.path.endsWith('/pending')
            ? [
                {
                  'id': 42,
                  'owner': {'id': 7, 'username': 'Inviter'},
                  'invited': {'id': 8},
                },
              ]
            : [],
      );
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(t.musicTools.sharingInvitationsTitle));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.musicTools.sharingInvitationAccept));
    await tester.pumpAndSettle();
    profile.retire();
    await tester.pump();
    await tester.tap(find.text(t.musicTools.sharingInvitationAccept).last);
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(find.text('Inviter'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invitation controls and confirmation fit 320px at 200 percent text', (tester) async {
    tester.view.physicalSize = const Size(320, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pump(
      tester,
      (request) async => jsonResponse(
        request.url.path.endsWith('/pending')
            ? [
                {
                  'id': 42,
                  'owner': {'id': 7, 'username': 'Inviter'},
                  'invited': {'id': 8},
                },
              ]
            : [],
      ),
      textScale: 2,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(t.musicTools.sharingInvitationsTitle));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(t.musicTools.sharingInvitationReject));
    await tester.tap(find.text(t.musicTools.sharingInvitationReject));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text(t.common.cancel));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
