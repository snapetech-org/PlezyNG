import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/sources/source_controller.dart';

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
}
