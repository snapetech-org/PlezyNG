import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/services/music/music_account_scope.dart';
import 'package:plezy/services/music/music_library_store.dart';
import 'package:plezy/services/music/music_offline_rating_account.dart';
import 'package:plezy/services/plex_auth_service.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/utils/active_client_scope.dart';

import '../../test_helpers/backend_client_fixtures.dart';
import '../../test_helpers/music_experience_fakes.dart';
import '../../test_helpers/prefs.dart';

void main() {
  late AppDatabase db;
  late ConnectionRegistry connections;
  late ProfileConnectionRegistry profiles;
  late MusicOfflineRatingAccounts accounts;
  var current = true;
  setUp(() async {
    resetSharedPreferencesForTest();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    connections = ConnectionRegistry(db);
    profiles = ProfileConnectionRegistry(db);
    current = true;
    await db
        .into(db.profiles)
        .insert(
          ProfilesCompanion.insert(id: 'p', kind: 'local', displayName: 'Profile', configJson: '{}', createdAt: 1),
        );
    accounts = MusicOfflineRatingAccounts(
      store: MusicLibraryStore(db, 'p'),
      connections: connections,
      profiles: profiles,
      current: () => current,
    );
  });
  tearDown(() => db.close());

  Future<void> bind({String id = 'plex.owner', String user = 'home-a', String? token = 'secret'}) async {
    await connections.upsert(
      PlexAccountConnection(
        id: id,
        accountToken: 'owner-secret',
        clientIdentifier: 'device',
        accountLabel: 'Account',
        createdAt: DateTime(2026),
        servers: [
          PlexServer(
            name: 'Music',
            clientIdentifier: 's',
            accessToken: 'resource-secret',
            connections: [
              PlexConnection(
                protocol: 'https',
                address: 'plex.example.com',
                port: 443,
                uri: 'https://plex.example.com',
                local: true,
                relay: false,
                ipv6: false,
              ),
            ],
            owned: false,
          ),
        ],
      ),
    );
    await profiles.upsert(ProfileConnection(profileId: 'p', connectionId: id, userIdentifier: user, userToken: token));
  }

  test('cold identity matches live Home user and never persists credentials', () async {
    await bind();
    final offline = (await accounts.forItem(musicTrack('a')))!;
    final live =
        testPlexClient(
            serverId: ServerId('s'),
            token: 'rotated-secret',
            profileScopeId: PlexProfileScopeId(serverId: ServerId('s'), profileId: 'p'),
          )
          ..plexAccountId = 'plex.owner'
          ..plexMusicUserIdentifier = 'home-a';
    addTearDown(live.close);
    expect(offline.scope, musicAccountScope(live));
    expect(offline.capabilities.numericUserRating, isTrue);
    expect(jsonEncode(offline.scope), isNot(contains('secret')));
    await bind(user: 'home-b');
    expect((await accounts.forItem(musicTrack('a')))!.scope, isNot(offline.scope));
  });
  test('unbound, ambiguous, missing-token and switched profiles fail closed', () async {
    expect(await accounts.forItem(musicTrack('a')), isNull);
    await bind(token: null);
    expect(await accounts.forItem(musicTrack('a')), isNull);
    await bind();
    expect(await accounts.forItem(musicTrack('a', server: 'other')), isNull);
    current = false;
    expect(await accounts.forItem(musicTrack('a')), isNull);
    current = true;
    await bind(id: 'plex.other');
    expect(await accounts.forItem(musicTrack('a')), isNull);
  });

  test('MediaBrowser cold ratings use the exact saved client namespace', () async {
    await connections.upsert(
      JellyfinConnection(
        id: 'saved-jellyfin-identity',
        baseUrl: 'https://jellyfin.example',
        serverName: 'Music',
        serverMachineId: 's',
        userId: 'user',
        userName: 'Listener',
        accessToken: 'secret',
        deviceId: 'device',
        createdAt: DateTime(2026),
      ),
    );
    await profiles.upsert(
      const ProfileConnection(
        profileId: 'p',
        connectionId: 'saved-jellyfin-identity',
        userIdentifier: 'user',
        userToken: 'secret',
      ),
    );
    final track = MediaItem.fromJson({...musicTrack('a').toJson(), 'backend': 'jellyfin'});
    final account = (await accounts.forItem(track))!;
    expect(account.scope, 'saved-jellyfin-identity');
    expect(account.capabilities.userFavorites, isTrue);
  });
}
