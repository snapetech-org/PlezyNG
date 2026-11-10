import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/music/music_library_store.dart';

void main() {
  late AppDatabase database;
  late MusicLibraryStore store;
  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    store = MusicLibraryStore(database, 'profile');
  });
  tearDown(() => database.close());

  test('snapshot pruning bounds metadata without deleting retry batches or other profiles', () async {
    for (var index = 0; index < 5; index++) {
      await store.saveDocument('stationSnapshot', '$index', {'id': '$index', 'pending': false});
    }
    await store.saveDocument('stationPending', 'retry', {'id': 'retry', 'pending': true});
    final other = MusicLibraryStore(database, 'other');
    await other.saveDocument('stationSnapshot', 'other', {'id': 'other'});
    await store.pruneStationSnapshots(maxSnapshots: 2);
    expect(await store.documents('stationSnapshot'), hasLength(2));
    expect(await store.pendingStationSnapshot('retry'), isNotNull);
    expect(await other.document('stationSnapshot', 'other'), isNotNull);
  });

  test('byte quota measures UTF-8 bytes and discards oversized snapshots', () async {
    await store.saveDocument('stationSnapshot', 'large', {'id': 'large', 'title': '🎵' * 100});
    await store.saveDocument('stationSnapshot', 'small', {'id': 'small'});
    await store.pruneStationSnapshots(maxBytes: 100);
    expect(await store.document('stationSnapshot', 'large'), isNull);
    expect(await store.document('stationSnapshot', 'small'), isNotNull);
  });

  test('legacy pending snapshots migrate before pruning even when larger than the quota', () async {
    await store.saveDocument('stationSnapshot', 'legacy', {
      'id': 'legacy',
      'pending': true,
      'tracks': ['keep'],
    });
    await store.pruneStationSnapshots(maxBytes: 1);
    expect(await store.document('stationSnapshot', 'legacy'), isNull);
    expect((await store.pendingStationSnapshot('legacy'))!['tracks'], ['keep']);
  });

  test('migration preserves a newer pending batch', () async {
    await store.saveDocument('stationSnapshot', 'legacy', {
      'id': 'legacy',
      'pending': true,
      'tracks': ['old'],
    });
    await store.saveDocument('stationPending', 'legacy', {
      'id': 'legacy',
      'pending': true,
      'tracks': ['new'],
    });
    await store.pruneStationSnapshots();
    expect((await store.pendingStationSnapshot('legacy'))!['tracks'], ['new']);
  });

  test('successful batches replace only their completed snapshot and retire their retry', () async {
    await store.saveDocument('stationPending', 'station', {'id': 'station', 'pending': true});
    await store.completeStationSnapshot('station', {
      'version': 1,
      'id': 'station',
      'tracks': ['new'],
    });
    expect(await store.pendingStationSnapshot('station'), isNull);
    expect((await store.document('stationSnapshot', 'station'))!['pending'], isFalse);
  });

  test('removed profiles cannot resurrect snapshots', () async {
    await database.deleteMusicRecipesForProfile('profile');
    await store.completeStationSnapshot('late', {'id': 'late'});
    await store.pruneStationSnapshots();
    expect(await MusicLibraryStore(database, 'profile').documents('stationSnapshot'), isEmpty);
  });
}
