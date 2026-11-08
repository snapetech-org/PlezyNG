import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/utils/log_redaction_manager.dart';
import 'package:plezy/utils/persistent_diagnostic_log.dart';

void main() {
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pleazyng-diagnostic-log-');
    file = File('${directory.path}/diagnostics.log');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('serializes bursts, bounds pending bytes and drains before closing', () async {
    final log = PersistentDiagnosticLog(file, maxBytes: 1024, maxPendingBytes: 128);
    for (var i = 0; i < 100; i++) {
      log.add('record-$i');
    }
    await log.close();
    final text = await file.readAsString();
    expect(text, endsWith('record-99\n'));
    expect(await file.length(), lessThanOrEqualTo(128));
    log.add('after close');
    expect(await file.readAsString(), text);
  });

  test('rotation retains only one bounded previous file', () async {
    final log = PersistentDiagnosticLog(file, maxBytes: 64);
    for (var i = 0; i < 8; i++) {
      log.add('record-$i abcdefghijklmnop');
      await log.flush();
    }
    await log.close();
    expect(await file.length(), lessThanOrEqualTo(64));
    expect(await File('${file.path}.previous').length(), lessThanOrEqualTo(64));
    expect(await directory.list().length, 2);
    expect(await file.readAsString(), contains('record-7'));
  });

  test('disk failure does not escape into app logging', () async {
    final obstruction = File('${directory.path}/not-a-directory');
    await obstruction.writeAsString('preserve');
    final log = PersistentDiagnosticLog(File('${obstruction.path}/diagnostics.log'));
    log.add('first');
    await log.flush();
    log.add('after disk failure');
    await log.close();
    expect(await obstruction.readAsString(), 'preserve');
  });

  test('persistent output receives redacted messages, errors and stacks', () async {
    MemoryLogOutput.clearLogs();
    final log = PersistentDiagnosticLog(file);
    final previous = setPersistentDiagnosticLog(log);
    const secret = 'persistent-diagnostic-private-token';
    LogRedactionManager.registerToken(secret);
    try {
      MemoryAwareLogPrinter(SimplePrinter()).log(
        LogEvent(
          Level.warning,
          'artwork failed credential=$secret',
          error: 'auth=$secret',
          stackTrace: StackTrace.fromString('trace $secret'),
        ),
      );
      await log.flush();
      final text = await file.readAsString();
      expect(text, contains('artwork failed'));
      expect(text, isNot(contains(secret)));
    } finally {
      setPersistentDiagnosticLog(previous);
      await log.close();
    }
  });
}
