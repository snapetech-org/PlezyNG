import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/music/music_account_scope.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/utils/active_client_scope.dart';

import '../../test_helpers/backend_client_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase database;
  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(database);
  });
  tearDown(() => database.close());
  test('direct Plex users are distinct without persisting a token', () {
    final first = testPlexClient(token: 'direct-secret-a');
    final second = testPlexClient(token: 'direct-secret-b');
    addTearDown(first.close);
    addTearDown(second.close);
    expect(musicAccountScope(first), isNot(musicAccountScope(second)));
    expect(musicAccountScope(first), isNot(contains('direct-secret-a')));
  });

  test('Plex Home users sharing an account cannot replay each other\'s edits', () {
    final first = testPlexClient(token: 'old-token')..plexAccountId = 'account-a';
    final sameUser = testPlexClient(token: 'old-token')..plexAccountId = 'account-a';
    final rotated = testPlexClient(token: 'new-token')..plexAccountId = 'account-a';
    final other = testPlexClient(token: 'other-token')..plexAccountId = 'account-b';
    addTearDown(first.close);
    addTearDown(sameUser.close);
    addTearDown(rotated.close);
    addTearDown(other.close);
    expect(musicAccountScope(first), musicAccountScope(sameUser));
    expect(musicAccountScope(first), isNot(musicAccountScope(rotated)));
    expect(musicAccountScope(first), isNot(musicAccountScope(other)));
  });

  test('verified Home user identity survives token rotation and isolates siblings', () {
    final first = testPlexClient(token: 'first-token')
      ..plexAccountId = 'account-a'
      ..plexMusicUserIdentifier = 'home-user-a';
    final rotated = testPlexClient(token: 'rotated-token')
      ..plexAccountId = 'account-a'
      ..plexMusicUserIdentifier = 'home-user-a';
    final sibling = testPlexClient(token: 'sibling-token')
      ..plexAccountId = 'account-a'
      ..plexMusicUserIdentifier = 'home-user-b';
    addTearDown(first.close);
    addTearDown(rotated.close);
    addTearDown(sibling.close);
    expect(musicAccountScope(first), musicAccountScope(rotated));
    expect(musicAccountScope(first), isNot(musicAccountScope(sibling)));
    expect(musicAccountScope(first), isNot(contains('home-user-a')));
  });

  test('portable history identity survives local profile and token changes but not Home users', () {
    final first = testPlexClient(token: 'old-secret')
      ..plexAccountId = 'account-a'
      ..plexMusicUserIdentifier = 'home-a';
    final otherDevice = testPlexClient(token: 'rotated-secret')
      ..profileScopeId = PlexProfileScopeId(serverId: first.serverId, profileId: 'another-local-profile')
      ..plexAccountId = 'account-a'
      ..plexMusicUserIdentifier = 'home-a';
    addTearDown(first.close);
    addTearDown(otherDevice.close);
    expect(musicHistoryAccountScope(first), musicHistoryAccountScope(otherDevice));
    expect(musicHistoryAccountScope(first), isNot(contains('secret')));
    otherDevice.plexMusicUserIdentifier = 'home-b';
    expect(musicHistoryAccountScope(first), isNot(musicHistoryAccountScope(otherDevice)));
    otherDevice.plexMusicUserIdentifier = null;
    expect(musicHistoryAccountScope(otherDevice), isNull);
  });
}
