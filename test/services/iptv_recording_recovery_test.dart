import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/iptv/iptv_models.dart';
import 'package:plezy/iptv/iptv_source_repository.dart';

import '../test_helpers/prefs.dart';

Future<void> _profile(AppDatabase database) => database.customStatement(
  "INSERT INTO profiles(id, kind, display_name, config_json, created_at) VALUES ('p', 'local', 'Local', '{}', 0)",
);

IptvLocalRecording _recording(String id, String path) => IptvLocalRecording(
  id: id, profileId: 'p', title: id, filePath: path, startedAt: DateTime.utc(2026), state: 'recording',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an unreadable archive cannot prevent another interrupted recording from recovering', () async {
    final directory = await Directory.systemTemp.createTemp('plezy-recording-recovery-');
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async { await database.close(); await directory.delete(recursive: true); });
    await _profile(database);
    final repository = IptvSourceRepository(database);
    final bad = File('${directory.path}/bad.m3u8');
    final media = await Directory('${directory.path}/bad.media').create();
    await bad.writeAsString('#EXTM3U\n#PLEZY-ARCHIVE:bad.media\nbad.media/video.m3u8\n');
    await File('${media.path}/video.m3u8').writeAsBytes([0xff, 0xfe, 0xff]);
    final good = File('${directory.path}/good.ts');
    await good.writeAsBytes([1, 2, 3]);
    await repository.beginLocalRecording(_recording('bad', bad.path));
    await repository.beginLocalRecording(_recording('good', good.path));

    await repository.recoverLocalRecordingSchedules();
    final rows = {for (final row in await repository.localRecordings('p')) row.id: row};
    expect(rows['bad']!.state, 'interrupted');
    expect(rows['bad']!.errorCode, 'recovery_data_invalid');
    expect(await bad.exists(), isTrue);
    expect(rows['good']!.state, 'interrupted');
    expect(rows['good']!.sizeBytes, 3);
    expect(await good.readAsBytes(), [1, 2, 3]);
  });

  test('legacy bootstrap interruptions are recoverable without reopening ordinary failed captures', () async {
    final directory = await Directory.systemTemp.createTemp('plezy-legacy-recovery-');
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async { await database.close(); await directory.delete(recursive: true); });
    await _profile(database);
    final repository = IptvSourceRepository(database);
    final file = File('${directory.path}/legacy.ts');
    await file.writeAsBytes([1, 2, 3, 4]);
    await repository.beginLocalRecording(_recording('legacy', file.path));
    await repository.beginLocalRecording(_recording('empty', '${directory.path}/absent.ts'));
    await database.customStatement("UPDATE iptv_recordings SET state='failed', error_code='interrupted' WHERE id='legacy'");
    await database.customStatement("UPDATE iptv_recordings SET state='failed', error_code='recording_empty' WHERE id='empty'");
    await repository.recoverLocalRecordingSchedules();
    final rows = {for (final row in await repository.localRecordings('p')) row.id: row};
    expect(rows['legacy']!.state, 'interrupted');
    expect(rows['legacy']!.sizeBytes, 4);
    expect(rows['empty']!.state, 'failed');
    expect(rows['empty']!.errorCode, 'recording_empty');
  });

  test('production database bootstrap preserves the state consumed by recording salvage', () async {
    resetSharedPreferencesForTest();
    final directory = await Directory.systemTemp.createTemp('plezy-bootstrap-recovery-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/app.sqlite');
    final initial = AppDatabase.forTesting(NativeDatabase(file));
    try {
      await _profile(initial);
      await IptvSourceRepository(initial).beginLocalRecording(_recording('live', '${directory.path}/live.ts'));
    } finally { await initial.close(); }
    final opened = await AppDatabase.open(databaseFile: file, isTvos: false);
    addTearDown(opened.database.close);
    final row = (await IptvSourceRepository(opened.database).localRecordings('p')).single;
    expect(row.state, 'interrupted');
    expect(row.errorCode, 'app_interrupted');
  });
}
