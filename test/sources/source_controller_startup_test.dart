import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/sources/source_controller.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:plezy/sources/source_models.dart';

import '../test_helpers/io_fakes.dart';

class _DelayedPathProvider extends FakePathProvider {
  _DelayedPathProvider(super.root);

  final release = Completer<void>();

  @override
  Future<String?> getApplicationSupportPath() async {
    await release.future;
    return super.getApplicationSupportPath();
  }
}

class _AbaSourceRepository extends SourceRepository {
  _AbaSourceRepository(super.database);

  final firstAliceStarted = Completer<void>();
  final releaseFirstAlice = Completer<void>();
  final firstAliceReturned = Completer<void>();
  final secondAliceStarted = Completer<void>();
  var aliceCalls = 0;

  @override
  Future<List<FileSource>> sources(String profile) async {
    if (profile == 'alice') {
      aliceCalls++;
      if (aliceCalls == 1) {
        firstAliceStarted.complete();
        await releaseFirstAlice.future;
        firstAliceReturned.complete();
        return const [
          FileSource(id: 'stale-alice-source', profileId: 'alice', kind: FileSourceKind.local, name: 'Stale'),
        ];
      }
      secondAliceStarted.complete();
      return const [
        FileSource(id: 'current-alice-source', profileId: 'alice', kind: FileSourceKind.local, name: 'Current'),
      ];
    }
    return const [FileSource(id: 'bob-source', profileId: 'bob', kind: FileSourceKind.local, name: 'Bob')];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('profile binding waits for source initialization and keeps the latest profile', () async {
    final root = Directory.systemTemp.createTempSync('plezy-source-startup-');
    final previous = PathProviderPlatform.instance;
    final paths = _DelayedPathProvider(root);
    PathProviderPlatform.instance = paths;
    final controller = SourceController();
    final settled = Completer<void>();
    controller.addListener(() {
      if (!controller.loading && !settled.isCompleted) settled.complete();
    });

    try {
      // MainApp's proxy binds the profile immediately, before the database's
      // first path lookup completes on a cold start.
      expect(() => controller.attachProfile('alice', blocked: false), returnsNormally);
      expect(() => controller.attachProfile('bob', blocked: false), returnsNormally);
      expect(controller.loading, isTrue);
      paths.release.complete();
      await controller.ready;
      await settled.future.timeout(const Duration(seconds: 10));

      expect(controller.profileId, 'bob');
      expect(controller.blocked, isFalse);
      expect(controller.failure, isNull);
      expect(controller.sources, isEmpty);
    } finally {
      if (!paths.release.isCompleted) paths.release.complete();
      await controller.ready;
      controller.dispose();
      // dispose queues shutdown after outstanding source writers settle.
      await Future<void>.delayed(Duration.zero);
      await controller.repository.database.close();
      PathProviderPlatform.instance = previous;
      root.deleteSync(recursive: true);
    }
  });

  test('A to B to A discards the first delayed A source snapshot', () async {
    final root = Directory.systemTemp.createTempSync('plezy-source-aba-');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(root);
    final repository = _AbaSourceRepository(SourceDatabase(NativeDatabase.memory()));
    final controller = SourceController(repository: repository);

    Future<void> waitForLoaded(String profile) async {
      if (controller.profileId == profile && !controller.loading) return;
      final loaded = Completer<void>();
      void listener() {
        if (controller.profileId == profile && !controller.loading && !loaded.isCompleted) loaded.complete();
      }

      controller.addListener(listener);
      try {
        await loaded.future.timeout(const Duration(seconds: 10));
      } finally {
        controller.removeListener(listener);
      }
    }

    try {
      await controller.ready;
      controller.attachProfile('alice', blocked: false);
      await repository.firstAliceStarted.future.timeout(const Duration(seconds: 10));

      controller.attachProfile('bob', blocked: false);
      await waitForLoaded('bob');
      controller.attachProfile('alice', blocked: false);
      await repository.secondAliceStarted.future.timeout(const Duration(seconds: 10));
      await waitForLoaded('alice');
      expect(controller.sources.map((source) => source.id), ['current-alice-source']);

      repository.releaseFirstAlice.complete();
      await repository.firstAliceReturned.future;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(controller.profileId, 'alice');
      expect(controller.sources.map((source) => source.id), ['current-alice-source']);
    } finally {
      if (!repository.releaseFirstAlice.isCompleted) repository.releaseFirstAlice.complete();
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      await repository.database.close();
      PathProviderPlatform.instance = previous;
      root.deleteSync(recursive: true);
    }
  });
}
