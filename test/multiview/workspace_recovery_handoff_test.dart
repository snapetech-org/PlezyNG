import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/multiview/workspace_controller.dart';
import 'package:plezy/multiview/workspace_models.dart';

WorkspaceSessionDescriptor item(String id) => WorkspaceSessionDescriptor(
  id: id,
  kind: MultiviewMediaKind.video,
  title: id,
  openedAt: DateTime.utc(2026),
  resume: WorkspaceResumeTarget(kind: WorkspaceResumeKind.library, providerId: 'server', itemId: id),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  MultiviewWorkspaceController controller() => MultiviewWorkspaceController()
    ..restoreLayout(
      WorkspaceSnapshot(sessions: [item('a')], placements: const {}, layoutMode: MultiviewLayoutMode.floating),
    );

  test('opening an item independently consumes stale pending recovery', () {
    final workspace = controller();
    final owner = Object();
    var current = item('a');
    workspace.watchRecovery(owner, () => current);
    workspace.snapshot();
    current = item('b');
    workspace.snapshot();
    expect(workspace.recoverableSessions, isEmpty);
    workspace.unwatchRecovery(owner);
    expect(workspace.snapshot().sessions, isEmpty);
    workspace.dispose();
  });

  test('new owner checkpoint does not invalidate its unfinished explicit handoff', () async {
    final workspace = controller();
    final finish = Completer<bool>();
    late bool Function() current;
    final recovery = workspace.recover('a', (_, guard) {
      current = guard;
      return finish.future;
    });
    workspace.watchRecovery(Object(), () => item('a'));
    workspace.snapshot();
    expect(current(), isTrue);
    finish.complete(true);
    expect(await recovery, isTrue);
    workspace.dispose();
  });
}
