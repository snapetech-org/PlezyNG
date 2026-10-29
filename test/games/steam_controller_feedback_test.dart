import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/games/steam_controller_feedback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const devices = MethodChannel('dev.universal_gamepad/methods');
  const receiver = MethodChannel('test/steam_feedback');
  tearDown(() {
    messenger.setMockMethodCallHandler(devices, null);
    messenger.setMockMethodCallHandler(receiver, null);
  });

  testWidgets('bounded feedback and SI motion use the assigned physical device', (tester) async {
    final calls = <MethodCall>[], motion = <MethodCall>[];
    messenger.setMockMethodCallHandler(devices, (call) async {
      calls.add(call);
      if (call.method == 'plezyControllerState') return [15, 1.0, 2.0, 3.0, 4.0, 5.0, 1000.0];
      return true;
    });
    messenger.setMockMethodCallHandler(receiver, (call) async {
      if (call.method == 'readControllerFeedback') {
        return [
          [42, 7, 100, 200, 90, 300, 400, 80, 1],
        ];
      }
      motion.add(call);
      return true;
    });
    final session = SteamControllerFeedbackSession(owner: 'a' * 32, motion: true);
    session.update(receiver, true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    final effect = calls.singleWhere((c) => c.method == 'plezyControllerEffects');
    expect(effect.arguments['deviceId'], 42);
    expect(effect.arguments['duration'], 90);
    expect(motion.single.arguments['az'], 19.6133);
    session.stop();
    await tester.pump();
    expect(calls.last.method, 'plezyReleaseEffects');
  });

  testWidgets('late polls never actuate a controller after ownership changes', (tester) async {
    final pending = Completer<Object?>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(devices, (call) async {
      calls.add(call.method);
      return true;
    });
    var reads = 0;
    messenger.setMockMethodCallHandler(receiver, (call) {
      reads++;
      return pending.future;
    });
    final session = SteamControllerFeedbackSession(owner: 'b' * 32);
    session.update(receiver, true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(reads, 1);
    session.stop();
    pending.complete([
      [42, 1, 65535, 65535, 1000, 0, 0, 0, 0],
    ]);
    await tester.pump();
    expect(calls, ['plezyClaimEffects', 'plezyReleaseEffects']);
  });

  testWidgets('late claim release keeps its old token and malformed output retires effects', (tester) async {
    final pending = Completer<bool>();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(devices, (call) async {
      calls.add(call);
      if (call.method == 'plezyClaimEffects' && calls.length == 1) return pending.future;
      return true;
    });
    messenger.setMockMethodCallHandler(
      receiver,
      (_) async => [
        [42, 1, 0, 0, 1001, 0, 0, 0, 0],
      ],
    );
    final old = SteamControllerFeedbackSession(owner: 'c' * 32);
    final next = SteamControllerFeedbackSession(owner: 'd' * 32);
    old.update(receiver, true);
    await tester.pump();
    next.update(receiver, true);
    await tester.pump();
    pending.complete(true);
    await tester.pump();
    expect(
      calls.where(
        (call) => call.method == 'plezyReleaseEffects' && (call.arguments['owner'] as String).startsWith('c' * 32),
      ),
      hasLength(1),
    );
    await tester.pump(const Duration(milliseconds: 20));
    expect(calls.where((c) => c.method == 'plezyControllerEffects'), isEmpty);
    expect(calls.last.arguments['owner'], startsWith('d' * 32));
    old.stop();
    next.stop();
  });
}
