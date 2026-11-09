import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/multiview/workspace_controller.dart';
import 'package:plezy/multiview/workspace_models.dart';
import 'package:plezy/multiview/workspace_persistence.dart';

class _Persistence implements WorkspaceSnapshotPersistence {
  WorkspaceSnapshot? value;
  final profiles = <String>[];
  @override
  Future<WorkspaceSnapshot?> read(String profileId) async => value;
  @override
  Future<void> write(String profileId, WorkspaceSnapshot snapshot) async {
    profiles.add(profileId);
    value = snapshot;
  }
}

WorkspaceSessionDescriptor _video([int position = 12000]) => WorkspaceSessionDescriptor(
  id: 'video:server:item',
  kind: MultiviewMediaKind.video,
  title: 'A saved video',
  hasAudio: true,
  hasVideo: true,
  openedAt: DateTime.utc(2026, 11, 9),
  resume: WorkspaceResumeTarget(
    kind: WorkspaceResumeKind.library,
    providerId: 'server',
    itemId: 'item',
    positionMs: position,
  ),
);

WorkspaceSnapshot _snapshot(List<WorkspaceSessionDescriptor> sessions) => WorkspaceSnapshot(
  sessions: sessions,
  placements: const {},
  layoutMode: MultiviewLayoutMode.floating,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('restart preserves unresolved identities across layout-only writes', () async {
    final saved = _Persistence()..value = _snapshot([_video()]);
    final workspace = MultiviewWorkspaceController(persistence: saved, profileId: 'a');
    await workspace.hydrate();
    expect(workspace.sessions, isEmpty);
    expect(workspace.recoverableSessions.single.resume!.positionMs, 12000);
    expect(workspace.sessionTrayVisible, isTrue);
    workspace.setLayoutMode(MultiviewLayoutMode.sideBySide);
    final encoded = jsonEncode(workspace.snapshot().toJson());
    expect(encoded, isNot(contains('://')));
    expect(WorkspaceSnapshot.fromJson(jsonDecode(encoded)).sessions.single.resume!.itemId, 'item');
    workspace.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(saved.profiles, everyElement('a'));
    expect(saved.value!.sessions.single.id, _video().id);
  });

  testWidgets('full-screen owner is checkpointed periodically without a pane', (tester) async {
    final saved = _Persistence();
    final workspace = MultiviewWorkspaceController(persistence: saved, profileId: 'a');
    await workspace.hydrate();
    final owner = Object();
    var position = 12000;
    workspace.watchRecovery(owner, () => _video(position));
    await tester.pump(const Duration(milliseconds: 300));
    position = 24000;
    await tester.pump(const Duration(seconds: 10));
    expect(workspace.sessions, isEmpty);
    expect(workspace.recoverableSessions, isEmpty);
    expect(saved.value!.sessions.single.resume!.positionMs, 24000);
    workspace.unwatchRecovery(owner);
    await tester.pump(const Duration(milliseconds: 300));
    expect(saved.value!.sessions, isEmpty);
    workspace.dispose();
    await tester.pump();
  });

  test('failure retains retry and duplicate resume requests do not start twice', () async {
    final workspace = MultiviewWorkspaceController()..restoreLayout(_snapshot([_video()]));
    final finish = Completer<bool>();
    var opens = 0;
    final first = workspace.recover(_video().id, (_, current) {
      opens++;
      expect(current(), isTrue);
      return finish.future;
    });
    expect(await workspace.recover(_video().id, (_, _) async { opens++; return true; }), isFalse);
    finish.complete(false);
    expect(await first, isFalse);
    expect(opens, 1);
    expect(workspace.recoverableSessions, hasLength(1));
    expect(await workspace.recover(_video().id, (_, _) async => true), isTrue);
    expect(workspace.recoverableSessions, isEmpty);
    workspace.dispose();
  });

  test('dismissal fences a pending resolver and does not erase other sessions', () async {
    final workspace = MultiviewWorkspaceController()..restoreLayout(_snapshot([_video()]));
    final finish = Completer<bool>();
    late bool Function() current;
    final operation = workspace.recover(_video().id, (_, guard) { current = guard; return finish.future; });
    expect(workspace.dismissRecovery(_video().id), isTrue);
    expect(current(), isFalse);
    finish.complete(true);
    expect(await operation, isFalse);
    expect(workspace.snapshot().sessions, isEmpty);
    workspace.dispose();
  });

  test('profile teardown fences pending resolution and retains its retry checkpoint', () async {
    final saved = _Persistence()..value = _snapshot([_video()]);
    final workspace = MultiviewWorkspaceController(persistence: saved, profileId: 'a');
    await workspace.hydrate();
    final finish = Completer<bool>();
    late bool Function() current;
    final operation = workspace.recover(_video().id, (_, guard) { current = guard; return finish.future; });
    workspace.dispose();
    expect(current(), isFalse);
    finish.complete(true);
    expect(await operation, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(saved.value!.sessions, hasLength(1));
    expect(saved.profiles, everyElement('a'));
  });

  test('rejects oversized snapshots and URL-shaped recovery identities', () {
    final value = _snapshot([_video()]).toJson();
    value['sessions'] = List.generate(65, (_) => _video().toJson());
    expect(() => WorkspaceSnapshot.fromJson(value), throwsFormatException);
    for (final invalid in ['https://user:secret@host/item', 'bad\nid', '']) {
      final target = _video().resume!.toJson()..['itemId'] = invalid;
      expect(() => WorkspaceResumeTarget.fromJson(target), throwsFormatException);
    }
    final invalid = _video().toJson()..['resume'] = [];
    expect(() => WorkspaceSessionDescriptor.fromJson(invalid), throwsFormatException);
  });
}
