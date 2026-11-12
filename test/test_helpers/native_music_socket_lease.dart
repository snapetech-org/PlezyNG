import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Native group peers use protocol-defined ports (including UDP 5000).
/// Flutter runs suites in separate processes, so an OS lock prevents fixtures
/// in different suites from receiving each other's PCM or discovery traffic.
/// The OS releases the lock if a test process is terminated.
void useNativeMusicSocketLease() {
  RandomAccessFile? lease;
  setUpAll(() async {
    final file = File('.dart_tool/native-music-sockets.lock');
    await file.parent.create(recursive: true);
    final opened = await file.open(mode: FileMode.append);
    try {
      await opened.lock(FileLock.blockingExclusive);
      lease = opened;
    } catch (_) {
      await opened.close();
      rethrow;
    }
  });
  tearDownAll(() async {
    final opened = lease;
    if (opened == null) return;
    lease = null;
    try {
      await opened.unlock();
    } finally {
      await opened.close();
    }
  });
}
