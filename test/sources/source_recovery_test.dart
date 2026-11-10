import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/multiview/source_recovery_binder.dart';
import 'package:plezy/multiview/workspace_controller.dart';
import 'package:plezy/multiview/workspace_models.dart';
import 'package:plezy/multiview/workspace_recovery.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_playback.dart';

import '../services/music/music_playback_service_test.dart' show FakePlayer, FakeMediaControlsManager;
import 'fixtures/memory_sources.dart';

class _Controls extends FakeMediaControlsManager {
  @override
  Future<void> setBackgroundMode(bool enabled) async {}

  @override
  Future<void> updateFileMetadata({
    required String title,
    String? author,
    String? album,
    Duration? duration,
    Uint8List? artwork,
  }) async {
    metadataTitles.add(title);
  }
}

class _RecoverySources extends MemorySources {
  _RecoverySources(super.repository, super.directory);
  final localFiles = <String>{};
  Completer<bool>? pendingLocal;
  SourceEntry? refreshed;
  var hydrationCount = 0;

  @override
  Future<bool> hasOfflineContent(SourceEntry entry, PublicationFile file) async =>
      pendingLocal == null ? localFiles.contains(file.fingerprint) : await pendingLocal!.future;

  @override
  Future<SourceEntry> hydrate(SourceEntry entry) async {
    hydrationCount++;
    return refreshed ?? entry;
  }
}

class _GatedPlayer extends FakePlayer {
  final requestedFocus = Completer<void>();
  final allowFocus = Completer<void>();
  bool gate = false;
  @override
  Future<bool> requestAudioFocus() async {
    if (gate) {
      requestedFocus.complete();
      await allowFocus.future;
    }
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SourceDatabase database;
  late SourceRepository repository;
  const first = PublicationFile(id: 'one', name: '01.m4b', mimeType: 'audio/mp4', durationMs: 180000);
  const second = PublicationFile(id: 'two', name: '02.m4b', mimeType: 'audio/mp4', durationMs: 180000);
  const entry = SourceEntry(
    sourceId: 'files',
    id: 'https://provider.example/book',
    title: 'Book',
    kind: SourceItemKind.audiobook,
    files: [first, second],
  );
  setUp(() {
    database = SourceDatabase(NativeDatabase.memory());
    repository = SourceRepository(database);
  });
  tearDown(() => database.close());

  test('opaque identity is scoped and survives metadata upserts', () async {
    await repository.cacheEntries('alice', [entry]);
    final identity = (await repository.recoveryIdentity('alice', entry))!;
    expect(identity, isNot(contains('://')));
    expect(identity, isNot(contains('provider')));
    expect((await repository.entryForRecovery('alice', 'files', identity))?.id, entry.id);
    expect(await repository.entryForRecovery('bob', 'files', identity), isNull);
    expect(await repository.entryForRecovery('alice', 'another-source', identity), isNull);
    await repository.cacheEntries('alice', [entry.copyWith(title: 'Updated')]);
    expect(await repository.recoveryIdentity('alice', entry), identity);
    expect((await repository.entryForRecovery('alice', 'files', identity))?.title, 'Updated');
    for (final invalid in ['', '1', '-1:abc', '1 OR 1=1', "999999999999999999999:${'a' * 64}"]) {
      expect(await repository.entryForRecovery('alice', 'files', invalid), isNull);
    }
  });

  test('deleted and reused row cannot resurrect another item', () async {
    await repository.cacheEntries('alice', [entry]);
    final identity = (await repository.recoveryIdentity('alice', entry))!;
    await database.customStatement('DELETE FROM entries');
    const other = SourceEntry(sourceId: 'files', id: 'other', title: 'Other', kind: SourceItemKind.audiobook);
    await repository.cacheEntries('alice', [other]);
    expect(await repository.entryForRecovery('alice', 'files', identity), isNull);
  });

  test('recovery resolves the exact edition order and rejects replacement or samples', () {
    WorkspaceResumeTarget target(List<String> files) =>
        WorkspaceResumeTarget(kind: WorkspaceResumeKind.source, providerId: 'files', itemId: 'opaque', fileIds: files);
    expect(recoverySourceFiles(entry, target([second.fingerprint, first.fingerprint]))!.map((f) => f.id), [
      'two',
      'one',
    ]);
    expect(recoverySourceFiles(entry, target([first.fingerprint, first.fingerprint])), isNull);
    expect(recoverySourceFiles(entry, target(['0' * 64])), isNull);
    const sample = PublicationFile(id: 'sample', name: 'sample.m4b', mimeType: 'audio/mp4', sampleOnly: true);
    const sampleEntry = SourceEntry(
      sourceId: 'files',
      id: 'sample',
      title: 'Sample',
      kind: SourceItemKind.audiobook,
      files: [sample],
    );
    expect(recoverySourceFiles(sampleEntry, target([sample.fingerprint])), isNull);
    final encoded = target([first.fingerprint]).toJson();
    expect(WorkspaceResumeTarget.fromJson(encoded).fileIds, [first.fingerprint]);
    encoded['fileIds'] = List.filled(257, first.fingerprint);
    expect(() => WorkspaceResumeTarget.fromJson(encoded), throwsFormatException);
    encoded['fileIds'] = ['https://provider.example/secret'];
    expect(() => WorkspaceResumeTarget.fromJson(encoded), throwsFormatException);
  });

  test('offline recovery verifies every selected file before bypassing the provider', () async {
    final directory = await Directory.systemTemp.createTemp('pleazyng-offline-recovery-');
    final sources = _RecoverySources(repository, directory);
    final target = WorkspaceResumeTarget(
      kind: WorkspaceResumeKind.source,
      providerId: entry.sourceId,
      itemId: 'opaque',
      fileIds: entry.audio.map((file) => file.fingerprint).toList(),
    );
    try {
      sources.localFiles.addAll(target.fileIds);
      expect(
        await resolveRecoverySourceEntry(sources: sources, cached: entry, target: target, isCurrent: () => true),
        same(entry),
      );
      expect(sources.hydrationCount, 0);

      sources.localFiles.remove(second.fingerprint);
      sources.refreshed = entry.copyWith(files: [first]);
      final refreshed = await resolveRecoverySourceEntry(
        sources: sources,
        cached: entry,
        target: target,
        isCurrent: () => true,
      );
      expect(sources.hydrationCount, 1);
      expect(recoverySourceFiles(refreshed!, target), isNull);

      sources.pendingLocal = Completer<bool>();
      var current = true;
      final pending = resolveRecoverySourceEntry(
        sources: sources,
        cached: entry,
        target: target,
        isCurrent: () => current,
      );
      current = false;
      sources.pendingLocal!.complete(true);
      expect(await pending, isNull);
      expect(sources.hydrationCount, 1);
    } finally {
      sources.dispose();
      await directory.delete(recursive: true);
    }
  });

  Future<void> exercise(
    Future<void> Function(SourcePlayback, _GatedPlayer, MemorySources, MultiviewWorkspaceController, Directory) run,
  ) async {
    final directory = await Directory.systemTemp.createTemp('pleazyng-source-recovery-');
    final sources = MemorySources(repository, directory);
    final native = _GatedPlayer();
    final controls = _Controls();
    final playback = SourcePlayback(
      sources,
      playerFactory: (_) => native,
      controlsFactory: () => controls,
      wakelockToggle: (_) async {},
    );
    final workspace = MultiviewWorkspaceController();
    final binder = SourceRecoveryBinder(workspace: workspace, playback: playback, profileId: 'alice');
    try {
      await repository.cacheEntries('alice', [entry]);
      await run(playback, native, sources, workspace, directory);
    } finally {
      binder.dispose();
      workspace.dispose();
      await playback.stop();
      playback.dispose();
      await playback.stop();
      controls.closeControllers();
      sources.dispose();
      await directory.delete(recursive: true);
    }
  }

  test(
    'background source owner checkpoints without retaining a player route',
    () => exercise((playback, native, sources, workspace, directory) async {
      await playback.start(
        entry,
        entry.audio,
        localOverrides: {for (final file in entry.audio) file.id: Uri.file('${directory.path}/${file.name}')},
      );
      for (var i = 0; i < 30 && workspace.snapshot().sessions.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final snapshot = workspace.snapshot();
      expect(snapshot.sessions, hasLength(1));
      expect(snapshot.sessions.single.resume!.fileIds, entry.audio.map((f) => f.fingerprint));
      expect(jsonEncode(snapshot.toJson()), isNot(contains('https://')));
      expect(workspace.sessions, isEmpty);
      await playback.stop();
      await Future<void>.delayed(Duration.zero);
      expect(workspace.snapshot().sessions, isEmpty);
    }),
  );

  test(
    'cancelled recovery cannot open after a delayed audio-focus grant',
    () => exercise((playback, native, sources, workspace, directory) async {
      native.gate = true;
      var current = true;
      final start = playback.start(
        entry,
        entry.audio,
        onlyIfIdle: true,
        isStartCurrent: () => current,
        localOverrides: {for (final file in entry.audio) file.id: Uri.file('${directory.path}/${file.name}')},
      );
      await native.requestedFocus.future;
      current = false;
      native.allowFocus.complete();
      await start;
      expect(native.openedUris, isEmpty);
      expect(playback.active, isFalse);
    }),
  );

  test(
    'resume never replaces an owner that started while resolution was pending',
    () => exercise((playback, native, sources, workspace, directory) async {
      await playback.start(
        entry,
        entry.audio,
        localOverrides: {for (final file in entry.audio) file.id: Uri.file('${directory.path}/${file.name}')},
      );
      final count = native.openedUris.length;
      const other = SourceEntry(
        sourceId: 'files',
        id: 'other',
        title: 'Other',
        kind: SourceItemKind.audiobook,
        files: [first],
      );
      await playback.start(other, other.audio, onlyIfIdle: true, isStartCurrent: () => true);
      expect(native.openedUris, hasLength(count));
      expect(playback.entry?.key, entry.key);
    }),
  );
}
