import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_part.dart';
import 'package:plezy/media/media_version.dart';
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
  test('a different account regenerates a pending station batch', () async {
    expect((await run((_) async => false))!.failed, isTrue);
    client.scopedServerId = 's/second-user';
    client.rows = [musicTrack('new')];
    final retried = <String>[];
    await run((item) async {
      retried.add(item.id);
      return true;
    });
    expect(retried, ['new']);
    expect(client.queries, hasLength(2));
    expect((await store.document('stationSnapshot', 'station'))!['accountScope'], 's/second-user');
  });
  test('foreign library identities in a saved retry regenerate instead of queueing', () async {
    await run((_) async => false);
    final pending = (await store.pendingStationSnapshot('station'))!;
    pending['tracks'] = [musicTrack('foreign').copyWith(libraryId: 'other').toJson()];
    await store.saveDocument('stationPending', 'station', pending);
    client.rows = [musicTrack('fresh')];
    final queued = <String>[];
    await run((track) async {
      queued.add(track.id);
      return true;
    });
    expect(queued, ['fresh']);
  });
  test('completed download bytes count toward a station budget across refreshes', () async {
    final station = (await store.document('station', 'station'))!..['storageLimitMiB'] = 1;
    await store.saveDocument('station', 'station', station);
    final rule = (await db.getSyncRule(key))!;
    await db.associateSyncRuleDownload(rule, 's:owned');
    await store.completeStationSnapshot('station', {
      'version': 1,
      'id': 'station',
      'tracks': ['keep'],
    });
    client.rows = [musicTrack('new', durationMs: 1000)];
    final result = await run(
      (_) async {
        fail('Existing copies exhaust the budget');
      },
      downloads: {
        's:owned': const DownloadProgress(
          globalKey: 's:owned',
          status: DownloadStatus.completed,
          downloadedBytes: 1048576,
          totalBytes: 1048576,
        ),
      },
    );
    expect(result!.queuedCount, 0);
    expect((await store.document('stationSnapshot', 'station'))!['tracks'], ['keep']);
  });
  test('exact source byte estimates survive repeated failed station retries', () async {
    final station = (await store.document('station', 'station'))!..['storageLimitMiB'] = 1;
    await store.saveDocument('station', 'station', station);
    client.rows = [
      musicTrack('exact').copyWith(
        mediaVersions: [
          const MediaVersion(
            id: 'version',
            parts: [MediaPart(id: 'part', sizeBytes: 500)],
          ),
        ],
      ),
    ];
    for (var attempt = 0; attempt < 3; attempt++) {
      expect((await run((_) async => false))!.failed, isTrue);
      expect((await store.pendingStationSnapshot('station'))!['estimatedBytes'], {'s:exact': 500});
    }
    final queued = <String>[];
    await run((track) async {
      queued.add(track.id);
      return true;
    });
    expect(queued, ['exact']);
    expect(client.queries, hasLength(1));
    expect((await store.document('stationSnapshot', 'station'))!['estimatedBytes'], {'s:exact': 500});
  });
  test('tampered retry byte estimates cannot bypass a station budget', () async {
    final station = (await store.document('station', 'station'))!..['storageLimitMiB'] = 1;
    await store.saveDocument('station', 'station', station);
    client.rows = [musicTrack('first', durationMs: 1000)];
    await run((_) async => false);
    final pending = (await store.pendingStationSnapshot('station'))!;
    pending['estimatedBytes'] = {'s:first': -1};
    await store.saveDocument('stationPending', 'station', pending);
    client.rows = [musicTrack('regenerated', durationMs: 1000)];
    final queued = <String>[];
    await run((track) async {
      queued.add(track.id);
      return true;
    });
    expect(queued, ['regenerated']);
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
