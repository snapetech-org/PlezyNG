import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/player_native.dart';
import 'package:plezy/multiview/native_video_window.dart';
import 'package:plezy/multiview/workspace_controller.dart';
import 'package:plezy/multiview/workspace_models.dart';

class _WindowPlayer extends PlayerNative {
  _WindowPlayer() : super(listenToNativeEvents: false) {
    initialized = true;
    handlePlayerEvent('playback-restart', null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('com.plezy/mpv_player');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(method, null));

  test('window actions keep the owner and reject stale tokens after return', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call);
      return true;
    });
    final player = _WindowPlayer();
    addTearDown(player.dispose);
    final actions = <NativeVideoWindowAction>[];
    var returned = 0;
    expect(await player.detachVideoWindow(
      title: 'Current source', geometryKey: List.filled(64, 'a').join(), labels: const {},
      onIntent: actions.add, onRestored: () => returned++,
    ), isTrue);
    final token = (calls.first.arguments as Map)['token'];
    player.handlePlayerEvent('detached-window-action', {'token': 'retired', 'action': 'togglePlayback'});
    player.handlePlayerEvent('detached-window-action', {'token': token, 'action': 'run'});
    player.handlePlayerEvent('detached-window-action', {'token': token, 'action': 'seekForward'});
    await Future<void>.delayed(Duration.zero);
    expect(actions, [NativeVideoWindowAction.seekForward]);

    await player.setVideoRect(left: 20, top: 30, right: 400, bottom: 250, devicePixelRatio: 2);
    expect(calls.where((call) => call.method == 'setVideoRect'), isEmpty);
    expect(await player.attachVideoWindow(), isTrue);
    expect(returned, 1);
    expect(player.hasNativeVideoWindow, isFalse);
    expect(calls.last.method, 'setVideoRect');
    expect((calls.last.arguments as Map)['left'], 20);
    player.handlePlayerEvent('detached-window-action', {'token': token, 'action': 'togglePlayback'});
    await Future<void>.delayed(Duration.zero);
    expect(actions, hasLength(1));
  });

  test('native close revokes queued controls before they can affect the returned owner', () async {
    Map? arguments;
    messenger.setMockMethodCallHandler(method, (call) async {
      if (call.method == 'detachVideoWindow') arguments = call.arguments as Map;
      return true;
    });
    final player = _WindowPlayer();
    addTearDown(player.dispose);
    final release = Completer<void>();
    var intents = 0, restored = 0;
    await player.detachVideoWindow(
      title: 'Owner', geometryKey: List.filled(64, 'b').join(), labels: const {},
      onIntent: (_) async { intents++; await release.future; }, onRestored: () => restored++,
    );
    final token = arguments!['token'];
    player.handlePlayerEvent('detached-window-action', {'token': token, 'action': 'togglePlayback'});
    await Future<void>.delayed(Duration.zero);
    for (var i = 0; i < 100; i++) {
      player.handlePlayerEvent('detached-window-action', {'token': token, 'action': 'seekForward'});
    }
    player.handlePlayerEvent('detached-window-action', {'token': token, 'action': 'restored'});
    release.complete();
    await Future<void>.delayed(Duration.zero);
    expect(intents, 1);
    expect(restored, 1);
    expect(player.hasNativeVideoWindow, isFalse);
  });

  test('workspace waits for a successful return before restoring the route', () async {
    final workspace = MultiviewWorkspaceController(profileId: 'one');
    addTearDown(workspace.dispose);
    final returned = Completer<bool>();
    var detached = true, restored = 0;
    final descriptor = WorkspaceSessionDescriptor(
      id: 'video:one', title: 'One', kind: MultiviewMediaKind.video, openedAt: DateTime.utc(2026),
    );
    workspace.register(WorkspaceSurfaceRegistration(
      descriptor: descriptor, buildSurface: (_) => const SizedBox(), onRestore: () => restored++,
      onAttachWindow: () async { final accepted = await returned.future; if (accepted) detached = false; return accepted; },
      onDetachWindow: () async => true, isWindowDetached: () => detached,
    ));
    expect(workspace.restore(descriptor.id), isTrue);
    expect(restored, 0);
    expect(workspace.isRestored(descriptor.id), isFalse);
    workspace.updateDescriptor(descriptor.copyWith(title: 'Updated metadata'));
    returned.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(restored, 1);
    expect(workspace.isRestored(descriptor.id), isTrue);
    expect(workspace.nativeWindowGeometryKey(null), matches(RegExp(r'^[a-f0-9]{64}$')));
    final otherProfile = MultiviewWorkspaceController(profileId: 'two');
    addTearDown(otherProfile.dispose);
    expect(workspace.nativeWindowGeometryKey(null), isNot(otherProfile.nativeWindowGeometryKey(null)));
  });
}
