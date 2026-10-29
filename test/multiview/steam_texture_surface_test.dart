import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/games/game_models.dart';
import 'package:plezy/games/steam_native_plane.dart';
import 'package:plezy/multiview/steam_game_workspace_surface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const receiver = MethodChannel('com.plezy/games/steam_receiver');
  const streamChannel = MethodChannel('com.plezy/games/steam_stream/99');
  SteamGameWorkspaceSession session() {
    final host = GameHost(id: '123', name: 'Desktop', address: 'desktop.local', protocol: GameProtocol.steam);
    return SteamGameWorkspaceSession(
      host: host,
      game: StreamGame(hostKey: host.key, id: '620', name: 'Portal 2'),
      touchControls: false,
    );
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(receiver, null);
    messenger.setMockMethodCallHandler(streamChannel, null);
  });

  testWidgets('desktop texture replays state and uses native dimensions', (tester) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(receiver, (call) async {
      expect(call.method, 'create');
      expect(call.arguments['hostId'], '123');
      expect(call.arguments['audioChannels'], 2);
      return {'id': 99, 'textureId': 7};
    });
    messenger.setMockMethodCallHandler(streamChannel, (call) async {
      calls.add(call);
      return call.method == 'getSessionState' ? 'playing' : null;
    });
    final stream = session();
    await stream.setAudioEnabled(true);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: stream.workspaceSurface())));
    await tester.pump();
    expect(find.byType(Texture), findsOneWidget);
    expect(stream.sessionState.value, 'playing');
    expect(calls.any((c) => c.method == 'setAudioEnabled' && c.arguments['enabled'] == true), isTrue);
    final response = Completer<void>();
    await messenger.handlePlatformMessage(
      streamChannel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('videoSize', {'width': 1280, 'height': 800})),
      (_) => response.complete(),
    );
    await response.future;
    await tester.pump();
    expect(tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio, 1.6);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(calls.any((c) => c.method == 'disconnect'), isFalse);
    stream.dispose();
    await tester.pump();
    expect(calls.where((c) => c.method == 'disconnect'), hasLength(1));
  }, skip: !Platform.isLinux);

  testWidgets('native plane replay, codec fallback and retirement share the retained view', (tester) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(receiver, (_) async => {'id': 99, 'textureId': 7, 'nativePlane': true});
    messenger.setMockMethodCallHandler(streamChannel, (call) async {
      calls.add(call);
      if (call.method == 'getSessionState') return 'playing';
      if (call.method == 'getNativePresentation') return true;
      return null;
    });
    final stream = session();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: stream.workspaceSurface())));
    await tester.pump();
    await tester.pump();
    expect(find.byType(Texture), findsNothing);
    expect(tester.widget<SteamNativePlane>(find.byType(SteamNativePlane)).enabled, isTrue);
    expect(calls.any((call) => call.method == 'setNativeRect' && call.arguments['width'] > 0), isTrue);
    await messenger.handlePlatformMessage(
      streamChannel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('nativePresentation', false)),
      (_) {},
    );
    await tester.pump();
    expect(find.byType(Texture), findsOneWidget);
    expect(tester.widget<SteamNativePlane>(find.byType(SteamNativePlane)).enabled, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(calls.any((call) => call.method == 'setNativeRect' && call.arguments['width'] == 0), isTrue);
    expect(calls.any((call) => call.method == 'disconnect'), isFalse);
    stream.dispose();
  }, skip: !Platform.isLinux);

  testWidgets('presentation can unmount and remount without recreating or stopping the receiver', (tester) async {
    var creates = 0;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(receiver, (_) async {
      creates++;
      return {'id': 99, 'textureId': 7};
    });
    messenger.setMockMethodCallHandler(streamChannel, (call) async {
      calls.add(call);
      return call.method == 'getSessionState' ? 'playing' : null;
    });
    final stream = session();
    await stream.setInputEnabled(true);
    await tester.pumpWidget(MaterialApp(home: stream.workspaceSurface()));
    await tester.pump();
    expect(stream.inputAvailable.value, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(stream.inputAvailable.value, isFalse);
    expect(stream.sessionState.value, 'playing');
    expect(calls.any((c) => c.method == 'disconnect'), isFalse);
    await tester.pumpWidget(MaterialApp(home: stream.workspaceSurface()));
    await tester.pump();
    expect(creates, 1);
    expect(find.byType(Texture), findsOneWidget);
    expect(stream.inputAvailable.value, isTrue);
    await tester.pumpWidget(const SizedBox());
    stream.dispose();
    await tester.pump();
    expect(calls.where((c) => c.method == 'disconnect'), hasLength(1));
  }, skip: !Platform.isLinux);

  testWidgets('late native creation is retired after its workspace was removed', (tester) async {
    final created = Completer<Map<String, int>>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(receiver, (_) => created.future);
    messenger.setMockMethodCallHandler(streamChannel, (call) async {
      calls.add(call.method);
      return null;
    });
    final stream = session();
    await tester.pumpWidget(MaterialApp(home: stream.workspaceSurface()));
    await tester.pumpWidget(const SizedBox());
    stream.dispose();
    created.complete({'id': 99, 'textureId': 7});
    await tester.pump();
    expect(calls, ['disconnect']);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isLinux);

  testWidgets('touch assistance uses its own channel state and retires with the input lease', (tester) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(receiver, (_) async => {'id': 99, 'textureId': 0});
    messenger.setMockMethodCallHandler(streamChannel, (call) async {
      calls.add(call);
      return call.method == 'getSessionState' ? 'playing' : null;
    });
    final stream = session();
    await stream.setInputEnabled(true);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: stream.workspaceSurface())));
    await tester.pump();
    await tester.tap(find.byTooltip('On-screen controller'));
    await tester.pump();
    final button = find.byKey(const ValueKey('a'));
    expect(button, findsOneWidget);
    final touch = await tester.startGesture(tester.getCenter(button));
    await tester.pump();
    expect(calls.where((c) => c.method == 'setTouchControllerState').last.arguments, {
      'buttons': {'a': true},
    });
    await stream.setInputEnabled(false);
    await tester.pump();
    expect(find.byKey(const ValueKey('a')), findsNothing);
    expect(calls.any((c) => c.method == 'releaseTouchControls'), isTrue);
    await touch.cancel();
    await tester.pumpWidget(const SizedBox());
    stream.dispose();
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isLinux);

  testWidgets('a timed-out native creation cannot attach or acquire input later', (tester) async {
    final created = Completer<Map<String, int>>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(receiver, (_) => created.future);
    messenger.setMockMethodCallHandler(streamChannel, (call) async {
      calls.add(call.method);
      return null;
    });
    final stream = session();
    await tester.pumpWidget(MaterialApp(home: stream.workspaceSurface()));
    await tester.pump(const Duration(seconds: 11));
    expect(stream.sessionState.value, 'failed');
    created.complete({'id': 99, 'textureId': 7});
    await tester.pump();
    expect(calls, ['disconnect']);
    expect(find.byType(Texture), findsNothing);
    await tester.pumpWidget(const SizedBox());
    stream.dispose();
  }, skip: !Platform.isLinux);
}
