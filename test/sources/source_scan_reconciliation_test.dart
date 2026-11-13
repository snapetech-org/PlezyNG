import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:plezy/sources/source_models.dart';

SourceRepository _repository() => SourceRepository(
  SourceDatabase(NativeDatabase.memory()),
  protect: (value) async => value,
  reveal: (value) async => value,
);

SourceEntry _entry(String id) =>
    SourceEntry(sourceId: 'library', id: id, title: 'Entry $id', kind: SourceItemKind.ebook);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a completed scan prunes entries that were not seen', () async {
    final repository = _repository();
    addTearDown(repository.database.close);
    await repository.cacheEntries('profile', [_entry('present'), _entry('missing')]);

    final generation = await repository.beginSourceScan('profile', 'library');
    await repository.markScannedEntries('profile', generation, [_entry('present')]);
    await repository.finishSourceScan('profile', 'library', generation, isCurrent: () => true);

    expect(await repository.entryById('profile', 'library', 'present'), isNotNull);
    expect(await repository.entryById('profile', 'library', 'missing'), isNull);
  });

  test('a cancelled scan leaves all cached entries intact', () async {
    final repository = _repository();
    addTearDown(repository.database.close);
    await repository.cacheEntries('profile', [_entry('present'), _entry('unvisited')]);

    final generation = await repository.beginSourceScan('profile', 'library');
    await repository.markScannedEntries('profile', generation, [_entry('present')]);
    await expectLater(
      repository.finishSourceScan('profile', 'library', generation, isCurrent: () => false),
      throwsA(isA<SourceException>().having((error) => error.reason, 'reason', SourceFailure.cancelled)),
    );

    expect(await repository.entryById('profile', 'library', 'present'), isNotNull);
    expect(await repository.entryById('profile', 'library', 'unvisited'), isNotNull);
  });

  test('a superseded scan cannot prune entries owned by the newer scan', () async {
    final repository = _repository();
    addTearDown(repository.database.close);
    await repository.cacheEntries('profile', [_entry('first'), _entry('second')]);

    final oldGeneration = await repository.beginSourceScan('profile', 'library');
    await repository.markScannedEntries('profile', oldGeneration, [_entry('first')]);
    final currentGeneration = await repository.beginSourceScan('profile', 'library');
    await repository.markScannedEntries('profile', currentGeneration, [_entry('second')]);

    await expectLater(
      repository.finishSourceScan('profile', 'library', oldGeneration, isCurrent: () => true),
      throwsA(isA<SourceException>().having((error) => error.reason, 'reason', SourceFailure.cancelled)),
    );
    expect(await repository.entryById('profile', 'library', 'first'), isNotNull);
    expect(await repository.entryById('profile', 'library', 'second'), isNotNull);

    await repository.finishSourceScan('profile', 'library', currentGeneration, isCurrent: () => true);
    expect(await repository.entryById('profile', 'library', 'first'), isNull);
    expect(await repository.entryById('profile', 'library', 'second'), isNotNull);
  });
}
