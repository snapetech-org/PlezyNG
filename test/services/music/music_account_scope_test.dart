import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/music/music_account_scope.dart';
import 'package:plezy/services/plex_api_cache.dart';

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
}
