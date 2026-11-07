import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/sources/source_database.dart';

import '../test_helpers/io_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('concurrent source and remote stores initialize one file without migration races', () async {
    final directory = await Directory.systemTemp.createTemp('pleazyng-source-open-');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(directory);
    final databases = <SourceDatabase>[];
    try {
      databases.addAll(await Future.wait(List.generate(4, (_) => SourceDatabase.open())));
      final repositories = databases.map(SourceRepository.new).toList();
      await Future.wait(repositories.map((repository) => repository.sources('alice')));
      await repositories.first.savePreference('alice', 'open-test', {'value': 42});
      expect(await repositories.last.preference('alice', 'open-test'), {'value': 42});
      await databases.first.close();
      databases.removeAt(0);
      expect(await repositories.last.preference('alice', 'open-test'), {'value': 42});
      for (final database in databases) {
        final version = await database.customSelect('PRAGMA user_version').getSingle();
        expect(version.read<int>('user_version'), database.schemaVersion);
      }
    } finally {
      await Future.wait(databases.map((database) => database.close()));
      PathProviderPlatform.instance = previous;
      await directory.delete(recursive: true);
    }
  });

  test('a failed open does not block a later connection', () async {
    final directory = await Directory.systemTemp.createTemp('pleazyng-source-retry-');
    final previous = PathProviderPlatform.instance;
    final paths = _FailFirstSupportPath(directory);
    PathProviderPlatform.instance = paths;
    SourceDatabase? database;
    try {
      await expectLater(SourceDatabase.open(), throwsStateError);
      database = await SourceDatabase.open();
      expect(await SourceRepository(database).sources('alice'), isEmpty);
      expect(paths.attempts, 2);
    } finally {
      await database?.close();
      PathProviderPlatform.instance = previous;
      await directory.delete(recursive: true);
    }
  });
}

class _FailFirstSupportPath extends FakePathProvider {
  _FailFirstSupportPath(super.root);

  int attempts = 0;

  @override
  Future<String?> getApplicationSupportPath() {
    if (++attempts == 1) return Future.error(StateError('Support path unavailable'));
    return super.getApplicationSupportPath();
  }
}
