import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/games/game_models.dart';
import 'package:plezy/games/steam_input_profile.dart';
import 'package:plezy/multiview/steam_game_workspace_surface.dart';
import 'package:plezy/services/gamepad_service.dart';
import 'package:universal_gamepad/universal_gamepad.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('com.plezy/games/steam_stream/99');
  Future<void> state(String state) {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('sessionState', state)),
      (_) => done.complete(),
    );
    return done.future;
  }

  SteamGameWorkspaceSession session({
    void Function()? onFirstFrame,
    SteamInputProfile? inputProfile,
    Future<void> Function(SteamInputProfile)? persist,
  }) {
    final host = GameHost(id: '123', name: 'Desktop', address: 'desktop.local', protocol: GameProtocol.steam);
    return SteamGameWorkspaceSession(
      host: host,
      game: StreamGame(hostKey: host.key, id: '620', name: 'Portal 2'),
      touchControls: false,
      onFirstFrame: onFirstFrame,
      inputProfile: inputProfile,
      persistInputProfile: persist,
    );
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final replaceReceiver in [false, true]) {
    test('delayed input revocation cannot overwrite a newer grant (replace receiver: $replaceReceiver)', () async {
      const replacement = MethodChannel('com.plezy/games/steam_stream/100');
      final reset = Completer<void>();
      final calls = <MethodCall>[];
      var delayReset = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (delayReset && call.method == 'resetInput') await reset.future;
        return null;
      });
      messenger.setMockMethodCallHandler(replacement, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(replacement, null));
      final stream = session();
      addTearDown(stream.dispose);
      stream.attachPlatformView(99);
      await state('playing');
      await stream.setInputEnabled(true);
      delayReset = true;
      final revoking = stream.setInputEnabled(false);
      await Future<void>.delayed(Duration.zero);
      expect(stream.inputAvailable.value, isFalse);
      if (replaceReceiver) stream.attachPlatformView(100);
      await stream.setInputEnabled(true);
      reset.complete();
      await revoking;
      expect(stream.inputAvailable.value, isTrue);
      expect(calls.where((c) => c.method == 'setInputEnabled').last.arguments, {'enabled': true});
    });
  }

  test('window and keyboard availability release effects and native input until focus returns', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final gamepads = GamepadService.instance;
    gamepads.debugSetWindowFocused(true);
    final stream = session();
    addTearDown(() {
      stream.dispose();
      gamepads.debugSetWindowFocused(true);
    });
    stream.attachPlatformView(99);
    await state('playing');
    await stream.setInputEnabled(true);
    expect(stream.inputAvailable.value, isTrue);
    gamepads.debugSetWindowFocused(false);
    await Future<void>.delayed(Duration.zero);
    expect(stream.inputAvailable.value, isFalse);
    expect(calls.where((c) => c.method == 'setInputEnabled').last.arguments['enabled'], isFalse);
    gamepads.debugSetWindowFocused(true);
    await Future<void>.delayed(Duration.zero);
    expect(stream.inputAvailable.value, isTrue);
    expect(stream.microphoneState.value, 1);
  });

  test('microphone stays opt-in and mutes on lease loss and dialog suspension', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'setMicrophoneEnabled') return true;
      if (call.method == 'getMicrophoneState') return 3;
      if (call.method == 'requestMicrophonePermission') return true;
      return null;
    });
    final stream = session();
    addTearDown(stream.dispose);
    stream.attachPlatformView(99);
    await stream.setInputEnabled(true);
    await state('playing');
    expect(calls.where((c) => c.method == 'setMicrophoneEnabled' && (c.arguments as Map)['enabled'] == true), isEmpty);
    expect(await stream.requestMicrophonePermission(), isTrue);
    expect(await stream.enableMicrophone(), isTrue);
    expect(stream.microphoneState.value, 3);
    await stream.setInputEnabled(false);
    expect(stream.microphoneState.value, 1);
    await stream.setInputEnabled(true);
    expect(stream.microphoneState.value, 1);
    expect(await stream.enableMicrophone(), isTrue);
    await stream.withInputSuspended(() async {
      expect(stream.microphoneState.value, 1);
    });
    expect(stream.microphoneState.value, 1);
    expect(
      calls.where((c) => c.method == 'setMicrophoneEnabled' && (c.arguments as Map)['enabled'] == true),
      hasLength(2),
    );
  });

  test('late microphone start is revoked after the presentation loses ownership', () async {
    final accepted = Completer<bool>();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'setMicrophoneEnabled') {
        if ((call.arguments as Map)['enabled'] == true) return accepted.future;
        return true;
      }
      return null;
    });
    final stream = session();
    addTearDown(stream.dispose);
    stream.attachPlatformView(99);
    await stream.setInputEnabled(true);
    await state('playing');
    final starting = stream.enableMicrophone();
    stream.detach();
    accepted.complete(true);
    expect(await starting, isFalse);
    expect(stream.microphoneState.value, 1);
    expect(calls.lastWhere((c) => c.method == 'setMicrophoneEnabled').arguments, {'enabled': false});
  });

  test('microphone permission and device rejection do not report recording', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'getMicrophoneState' ? 1 : false);
    final stream = session();
    addTearDown(stream.dispose);
    stream.attachPlatformView(99);
    await stream.setInputEnabled(true);
    await state('playing');
    expect(await stream.requestMicrophonePermission(), isFalse);
    expect(await stream.enableMicrophone(), isFalse);
    expect(stream.microphoneState.value, 1);
  });

  test('custom mapping gates input until acknowledgement and replays after fallback', () async {
    final commands = <MethodCall>[];
    var gate = Completer<bool>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      commands.add(call);
      if (call.method == 'setControllerMapping') return gate.future;
      return null;
    });
    final stream = session(inputProfile: SteamInputProfile.defaults().change(0, 1, 1));
    addTearDown(stream.dispose);
    stream.attachPlatformView(99);
    await stream.setInputEnabled(true);
    await state('playing');
    expect(stream.inputAvailable.value, isFalse);
    gate.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(stream.inputAvailable.value, isTrue);
    gate = Completer<bool>();
    await state('reconnecting');
    await state('playing');
    expect(stream.inputAvailable.value, isFalse);
    gate.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(stream.inputAvailable.value, isTrue);
    expect(commands.where((c) => c.method == 'setControllerMapping'), hasLength(2));
  });

  test('rejected mapping is not saved and failed rollback holds input', () async {
    var saved = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setControllerMapping') return false;
      return null;
    });
    final stream = session(
      persist: (_) async {
        saved = true;
      },
    );
    addTearDown(stream.dispose);
    stream.attachPlatformView(99);
    await state('playing');
    await stream.setInputEnabled(true);
    await expectLater(stream.applyInputProfile(SteamInputProfile.defaults().change(0, 1, 1)), throwsStateError);
    expect(saved, isFalse);
    expect(stream.inputProfile.isDefault, isTrue);
    expect(stream.inputAvailable.value, isFalse);
    expect(stream.mappingFailed.value, isTrue);
  });

  test('retired receiver cannot finish saving a mapping', () async {
    final gate = Completer<bool>();
    var saved = false;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'setControllerMapping' ? gate.future : null,
    );
    final stream = session(
      persist: (_) async {
        saved = true;
      },
    );
    stream.attachPlatformView(99);
    await state('playing');
    final applied = stream.applyInputProfile(SteamInputProfile.defaults().change(0, 1, 1));
    final rejected = expectLater(applied, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    stream.dispose();
    gate.complete(true);
    await rejected;
    expect(saved, isFalse);
  });

  test('host shortcuts require the live input lease and always release modifiers', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final stream = session();
    addTearDown(stream.dispose);
    stream.attachPlatformView(99);
    await state('playing');
    expect(await stream.sendShortcut(SteamStreamShortcut.overlay), isFalse);
    expect(calls.where((c) => c.method == 'inputKey'), isEmpty);
    await stream.setInputEnabled(true);
    expect(await stream.sendShortcut(SteamStreamShortcut.overlay), isTrue);
    expect(calls.where((c) => c.method == 'inputKey').map((c) => c.arguments), [
      {'usage': 225, 'key': 'Shift Left', 'down': true},
      {'usage': 43, 'key': 'Tab', 'down': true},
      {'usage': 43, 'key': 'Tab', 'down': false},
      {'usage': 225, 'key': 'Shift Left', 'down': false},
    ]);
  });

  test('host shortcut stops on lease loss and releases an acknowledged key', () async {
    final calls = <MethodCall>[];
    final stream = session();
    addTearDown(stream.dispose);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'inputKey' && (call.arguments as Map)['down'] == true) await stream.setInputEnabled(false);
      return null;
    });
    stream.attachPlatformView(99);
    await state('playing');
    await stream.setInputEnabled(true);
    expect(await stream.sendShortcut(SteamStreamShortcut.overlay), isFalse);
    expect(calls.where((c) => c.method == 'inputKey').map((c) => c.arguments), [
      {'usage': 225, 'key': 'Shift Left', 'down': true},
      {'usage': 225, 'key': 'Shift Left', 'down': false},
    ]);
  });

  test('composed text uses bounded UTF-8 only with a live input lease', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'inputText' ? true : null;
    });
    final stream = session();
    addTearDown(stream.dispose);
    stream.attachPlatformView(99);
    await state('playing');
    expect(await stream.sendComposedText('hello'), isFalse);
    await stream.setInputEnabled(true);
    expect(await stream.sendComposedText('日本語 🙂'), isTrue);
    expect((calls.where((c) => c.method == 'inputText').single.arguments as Map)['text'], utf8.encode('日本語 🙂'));
    for (final invalid in ['', '🙂' * 129, '\u0000', '\u001b', '\u0085']) {
      expect(await stream.sendComposedText(invalid), isFalse);
    }
    expect(calls.where((c) => c.method == 'inputText'), hasLength(1));
    stream.detach();
    expect(await stream.sendComposedText('late'), isFalse);
  });

  test('disconnect acknowledgement permits reconnect after a texture channel retires', () async {
    var stops = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getSessionState') return 'playing';
      if (call.method == 'disconnect') {
        stops++;
        messenger.setMockMethodCallHandler(channel, null);
      }
      return null;
    });
    final stream = session();
    addTearDown(stream.dispose);
    stream.attachPlatformView(99);
    await state('playing');
    await stream.disconnect();
    expect(stream.sessionState.value, 'disconnected');
    await stream.reconnect();
    expect(stops, 1);
    expect(stream.sessionState.value, 'connecting');
    expect(stream.surfaceGeneration.value, 1);
  });

  test('closing diagnostics cannot reclaim a retired input lease', () async {
    final commands = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      commands.add(call);
      return call.method == 'getSessionState' ? 'playing' : null;
    });
    final stream = session();
    addTearDown(stream.dispose);
    stream.attachPlatformView(99);
    await state('playing');
    await stream.setInputEnabled(true);
    final closed = Completer<void>(), opened = Completer<void>();
    final dialog = stream.withInputSuspended(() async {
      opened.complete();
      await closed.future;
    });
    await opened.future;
    expect(commands.last.arguments, {'enabled': false});
    await state('playing'); // A duplicate state callback must not restore input.
    expect(commands.last.arguments, {'enabled': false});
    await stream.setInputEnabled(false); // Another pane/profile took ownership.
    closed.complete();
    await dialog;
    expect(commands.last.arguments, {'enabled': false});
  });

  test('pointer and keyboard input require a playing lease and bounded coordinates', () async {
    final commands = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      commands.add(call);
      return call.method == 'getSessionState' ? 'playing' : null;
    });
    final stream = session();
    addTearDown(stream.dispose);
    stream.attachPlatformView(99);
    await state('playing');
    commands.clear();
    stream.handlePointer(const Offset(.5, .5), button: 1, down: true);
    await Future<void>.delayed(Duration.zero);
    expect(commands, isEmpty);
    await stream.setInputEnabled(true);
    commands.clear();
    stream.handlePointer(const Offset(-2, 9), button: 1, down: true);
    stream.handlePointer(const Offset(double.nan, .5));
    stream.handlePointer(const Offset(.5, .5), button: 9);
    stream.handleWheel(2);
    stream.handleWheel(99);
    stream.handleNativeKey(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyW,
        logicalKey: LogicalKeyboardKey.keyW,
        timeStamp: Duration.zero,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(commands.map((c) => c.method), ['inputMouse', 'inputWheel', 'inputKey']);
    expect(commands.first.arguments, {'x': 0.0, 'y': 1.0, 'button': 1, 'down': true});
    expect((commands.last.arguments as Map)['usage'], 26);
    await stream.setInputEnabled(false);
    commands.clear();
    stream.handleWheel(1);
    stream.handlePointer(const Offset(.5, .5));
    await Future<void>.delayed(Duration.zero);
    expect(commands, isEmpty);
  });

  test('missing metrics support preserves the stream', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getSessionState') return 'playing';
      if (call.method == 'getStreamMetrics') throw MissingPluginException();
      return null;
    });
    final stream = session();
    addTearDown(stream.dispose);
    stream.attachPlatformView(99);
    await state('playing');
    expect(await stream.readMetrics(), isNull);
    expect(stream.sessionState.value, 'playing');
  });

  test('controller events retain device identity and disconnect releases only that controller', () async {
    final commands = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      commands.add(call);
      return call.method == 'getSessionState' ? 'playing' : null;
    });
    final stream = session();
    addTearDown(stream.dispose);
    stream.attachPlatformView(99);
    await state('playing');
    await stream.setInputEnabled(true);
    commands.clear();
    final gamepads = GamepadService.instance;
    gamepads.debugSetWindowFocused(true);
    gamepads.debugHandleGamepadEvent(
      GamepadButtonEvent(gamepadId: 12, timestamp: 1, button: GamepadButton.a, pressed: true, value: 1),
    );
    gamepads.debugHandleGamepadEvent(
      GamepadAxisEvent(gamepadId: 23, timestamp: 2, axis: GamepadAxis.leftStickX, value: .5),
    );
    gamepads.debugHandleGamepadEvent(
      GamepadConnectionEvent(
        gamepadId: 12,
        timestamp: 3,
        connected: false,
        info: const GamepadInfo(id: 12, name: 'First'),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(commands.map((c) => c.method), [
      'setControllerDeviceState',
      'setControllerDeviceState',
      'disconnectController',
    ]);
    expect(commands[0].arguments, {
      'deviceId': 12,
      'buttons': {'a': true},
    });
    expect(commands[1].arguments, {
      'deviceId': 23,
      'axes': {'leftStickX': .5},
    });
    expect(commands[2].arguments, {'deviceId': 12});
    await stream.setInputEnabled(false);
    expect(commands.any((c) => c.method == 'resetInput'), isTrue);
    commands.clear();
    stream.handleInput(
      GamepadButtonEvent(gamepadId: 23, timestamp: 4, button: GamepadButton.b, pressed: true, value: 1),
    );
    expect(commands, isEmpty);
  });

  test('late attachment replay cannot replace a newer first-frame event', () async {
    final replay = Completer<String>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getSessionState') return replay.future;
      return null;
    });
    final stream = session();
    addTearDown(stream.dispose);
    stream.attachPlatformView(99);
    await state('playing');
    replay.complete('connecting');
    await Future<void>.delayed(Duration.zero);
    expect(stream.sessionState.value, 'playing');
  });

  test('state replay records first frame once and input waits for playback', () async {
    var frames = 0;
    final commands = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      commands.add(call);
      return call.method == 'getSessionState' ? 'connecting' : null;
    });
    final stream = session(onFirstFrame: () => frames++);
    addTearDown(stream.dispose);
    stream.attachPlatformView(99);
    await stream.setInputEnabled(true);
    expect(commands.where((c) => c.method == 'setInputEnabled').last.arguments, {'enabled': false});
    await state('playing');
    await state('playing');
    expect(frames, 1);
    expect(commands.where((c) => c.method == 'setInputEnabled').last.arguments, {'enabled': true});
    await state('failed');
    expect(commands.where((c) => c.method == 'setInputEnabled').last.arguments, {'enabled': false});
    expect(commands.last.method, 'resetInput');
    await state('untrusted-unknown-state');
    expect(stream.sessionState.value, 'failed');
  });

  test('reconnect waits for teardown, coalesces taps and ignores stale native states', () async {
    final stopped = Completer<void>();
    var disconnects = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getSessionState') return 'disconnected';
      if (call.method == 'disconnect') {
        disconnects++;
        await stopped.future;
      }
      return null;
    });
    final stream = session();
    addTearDown(stream.dispose);
    stream.attachPlatformView(99);
    await state('disconnected');
    final pending = stream.reconnect();
    await stream.reconnect();
    await state('playing');
    expect(stream.sessionState.value, 'reconnecting');
    expect(stream.surfaceGeneration.value, 0);
    expect(disconnects, 1);
    stopped.complete();
    await pending;
    expect(stream.surfaceGeneration.value, 1);
    expect(stream.sessionState.value, 'connecting');
  });

  test('failed teardown does not create an overlapping session', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getSessionState') return 'failed';
      if (call.method == 'disconnect') throw PlatformException(code: 'STREAM_STOP_PENDING');
      return null;
    });
    final stream = session();
    addTearDown(stream.dispose);
    stream.attachPlatformView(99);
    await state('failed');
    await stream.reconnect();
    expect(stream.surfaceGeneration.value, 0);
    expect(stream.sessionState.value, 'failed');
  });

  test('profile retirement during teardown cannot recreate its surface', () async {
    final stopped = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getSessionState') return 'failed';
      if (call.method == 'disconnect') await stopped.future;
      return null;
    });
    final stream = session();
    stream.attachPlatformView(99);
    await state('failed');
    var creations = 0;
    stream.surfaceGeneration.addListener(() => creations++);
    final pending = stream.reconnect();
    stream.dispose();
    stopped.complete();
    await pending;
    expect(creations, 0);
  });

  test('Steam workspace surface arguments stay structured and non-secret', () {
    final host = GameHost(
      id: '76561198000000000',
      name: 'Living room PC',
      address: '192.168.1.10',
      protocol: GameProtocol.steam,
      port: 27036,
    );
    final game = StreamGame(hostKey: host.key, id: '0', name: 'Big Picture');
    final session = SteamGameWorkspaceSession(host: host, game: game, touchControls: false);

    expect(session.creationParams, containsPair('hostId', host.id));
    expect(session.creationParams, containsPair('hostKey', 'steam:${host.id}'));
    expect(session.creationParams, containsPair('address', host.address));
    expect(session.creationParams, containsPair('port', 27036));
    expect(session.creationParams, containsPair('appId', '0'));
    expect(session.creationParams, containsPair('touchControls', false));
    expect(session.creationParams, containsPair('audioChannels', 2));
    expect(session.creationParams.keys, isNot(contains('password')));
    expect(SteamGameWorkspaceSession.channelNameForViewId(7), 'com.plezy/games/steam_stream/7');
    expect(session.workspaceSurface().key, same(session.workspaceSurface().key));

    session.dispose();
  });
}
