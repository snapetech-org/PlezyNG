import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/services/music/music_library_store.dart';
import 'package:plezy/services/music/music_station.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/sync_rule_executor.dart';
import '../../test_helpers/music_experience_fakes.dart';
import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late MusicLibraryStore store;
  late ExperienceClient client;
  late MultiServerManager manager;
  late SyncRuleExecutor executor;
  const key = 'p|s:station';
  setUp(() async {
    resetSharedPreferencesForTest();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = MusicLibraryStore(db, 'p');
    client = ExperienceClient()..rows = [musicTrack('a'), musicTrack('b')];
    manager = MultiServerManager()..debugRegisterClientForTesting(client);
    executor = SyncRuleExecutor(database: db);
    await store.saveDocument(
      'station',
      'station',
      MusicStation(
        id: 'station',
        title: 'Station',
        serverId: 's',
        libraryId: 'library',
        refreshHours: 6,
        wifiOnly: false,
      ).toJson(),
    );
    await db.insertSyncRule(
      profileId: 'p',
      serverId: ServerId('s'),
      ratingKey: 'station',
      globalKey: key,
      targetType: 'musicStation',
      episodeCount: 100,
      downloadFilter: 'all',
      downloadLinksInitialized: true,
    );
  });
  tearDown(() async {
    manager.dispose();
    await db.close();
  });
  Future<SyncRuleResult?> run(
    Future<bool> Function(MediaItem) queue, {
    Map<String, DownloadProgress> downloads = const {},
  }) => executor.executeSingleRule(
    profileId: 'p',
    globalKey: key,
    serverManager: manager,
    downloads: downloads,
    metadata: const {},
    associateDownload: (rule, key) => db.associateSyncRuleDownload(rule, key),
    queueSingleDownload: (item, client, {int mediaIndex = 0, Object? downloadQuality}) => queue(item),
    deleteSyncRuleDownload: (_) async {
      fail('Station top-up must never silently delete downloads');
    },
    isOffline: false,
  );
  test('station downloads preserve membership links and respect the refresh interval', () async {
    final queued = <String>[];
    final first = await run((item) async {
      queued.add(item.id);
      return true;
    });
    expect(first!.queuedCount, 2);
    expect(queued, ['a', 'b']);
    final rule = (await db.getSyncRule(key))!;
    expect(await db.getSyncRuleDownloadLinks(rule.id), hasLength(2));
    expect((await store.document('stationSnapshot', 'station'))!['pending'], isFalse);
    expect(
      await run((_) async {
        fail('Refresh interval not reached');
      }),
      isNull,
    );
  });
  test('failed batch retries its same candidates instead of drawing another random page', () async {
    expect((await run((_) async => false))!.failed, isTrue);
    client.rows = [musicTrack('new')];
    final retried = <String>[];
    await run((item) async {
      retried.add(item.id);
      return true;
    });
    expect(retried, ['a', 'b']);
    expect(client.queries, hasLength(1));
  });
  test('editing a rule during generation invalidates the batch', () async {
    final pending = Completer<LibraryPage<MediaItem>>();
    client.page = (_) => pending.future;
    final task = run((_) async {
      fail('Changed recipe must not queue');
    });
    while (client.queries.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final edited = (await store.document('station', 'station'))!..['title'] = 'Changed';
    await store.saveDocument('station', 'station', edited);
    pending.complete(LibraryPage(items: [musicTrack('late')], totalCount: 1));
    expect(await task, isNull);
    expect(await store.document('stationSnapshot', 'station'), isNull);
  });
  test('deleted profile prevents a late batch from persisting or queueing', () async {
    final pending = Completer<LibraryPage<MediaItem>>();
    client.page = (_) => pending.future;
    final task = run((_) async {
      fail('Removed profile must not queue');
    });
    while (client.queries.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await db.deleteMusicRecipesForProfile('p');
    pending.complete(LibraryPage(items: [musicTrack('late')], totalCount: 1));
    expect(await task, isNull);
    expect(await MusicLibraryStore(db, 'p').documents('stationSnapshot'), isEmpty);
  });
}
