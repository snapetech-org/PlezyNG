import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/music/music_anniversaries.dart';
import 'package:plezy/services/music/music_library_store.dart';
import '../../test_helpers/music_experience_fakes.dart';

MediaItem album(String id, String date) => musicTrack(id).copyWith(kind: MediaKind.album, originallyAvailableAt: date);

void main() {
  final today = DateTime(2026, 11, 9);
  late AppDatabase database;
  late MusicLibraryStore store;
  late ExperienceClient client;
  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    store = MusicLibraryStore(database, 'p');
    client = ExperienceClient();
  });
  tearDown(() => database.close());
  Future<List<MediaItem>> load({int epoch = 0}) =>
      MusicAnniversaries(store).load(client, 'library', now: today, contentEpoch: epoch, isCurrent: () => true);

  test('uses precise calendar dates, rejecting missing days, invalid dates and this year', () {
    expect(isMusicAnniversary(album('a', '2000-11-09T00:00:00Z'), today), isTrue);
    for (final date in ['2000', '2000-11', '2026-11-09', '2027-11-09', '2000-11-08', '2000-13-09']) {
      expect(isMusicAnniversary(album('a', date), today), isFalse, reason: date);
    }
    expect(isMusicAnniversary(album('leap', '2004-02-29'), DateTime(2026, 2, 28)), isFalse);
    expect(isMusicAnniversary(album('leap', '2004-02-29'), DateTime(2028, 2, 29)), isTrue);
    expect(isMusicAnniversary(album('bad', '2005-02-29'), DateTime(2028, 3, 1)), isFalse);
  });
  test('scans beyond the first page, excludes foreign libraries and caches only credentials-free identities', () async {
    client.page = (query) async => LibraryPage(
      items: query.offset == 0
          ? [album('other-day', '2000-01-01')]
          : [
              album('match', '2000-11-09').copyWith(raw: {'token': 'secret'}, thumbPath: 'https://host?token=secret'),
              album('foreign', '2000-11-09').copyWith(serverId: 'other'),
            ],
      totalCount: 3,
    );
    expect((await load()).map((item) => item.id), ['match']);
    expect(client.queries.map((q) => q.offset), [0, 1]);
    expect((await store.document('anniversaries', 's:library')).toString(), isNot(contains('secret')));
    expect(await load(), hasLength(1));
    expect(client.queries, hasLength(2));
    await load(epoch: 1);
    expect(client.queries, hasLength(4));
    client.scopedServerId = 's/new-user';
    client.rows = [];
    client.page = null;
    expect(await load(epoch: 1), isEmpty);
  });
  test('account revocation during a page prevents result and cache publication', () async {
    final pending = Completer<LibraryPage<MediaItem>>();
    final entered = Completer<void>();
    client.page = (_) {
      entered.complete();
      return pending.future;
    };
    final work = load();
    await entered.future;
    client.authenticationSessionId = Object();
    pending.complete(LibraryPage(items: [album('private', '2000-11-09')], totalCount: 1));
    await expectLater(work, throwsStateError);
    expect(await store.documents('anniversaries'), isEmpty);
  });
  test('a server ignoring offsets fails instead of caching a truncated index', () async {
    client.page = (_) async => LibraryPage(items: [album('repeated', '2000-11-09')], totalCount: 1000);
    await expectLater(load(), throwsStateError);
    expect(client.queries, hasLength(2));
    expect(await store.documents('anniversaries'), isEmpty);
  });
}
