import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/back_press.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/utils/platform_detector.dart';

KeyDownEvent _down(LogicalKeyboardKey key) =>
    KeyDownEvent(physicalKey: PhysicalKeyboardKey.escape, logicalKey: key, timeStamp: Duration.zero);
KeyRepeatEvent _repeat(LogicalKeyboardKey key) =>
    KeyRepeatEvent(physicalKey: PhysicalKeyboardKey.escape, logicalKey: key, timeStamp: Duration.zero);
KeyUpEvent _up(LogicalKeyboardKey key) =>
    KeyUpEvent(physicalKey: PhysicalKeyboardKey.escape, logicalKey: key, timeStamp: Duration.zero);

void main() {
  setUp(() => TvDetectionService.debugSetAppleTVOverride(false));
  tearDown(() => TvDetectionService.debugSetAppleTVOverride(null));

  group('BackPressGate', () {
    test('a full press acts once, on KeyUp, and consumes every phase', () {
      final gate = BackPressGate();
      var fired = 0;
      void onBack() => fired++;

      expect(gate.handle(_down(LogicalKeyboardKey.goBack), onBack), KeyEventResult.handled);
      expect(fired, 0);
      expect(gate.handle(_repeat(LogicalKeyboardKey.goBack), onBack), KeyEventResult.handled);
      expect(fired, 0);
      expect(gate.handle(_up(LogicalKeyboardKey.goBack), onBack), KeyEventResult.handled);
      expect(fired, 1);
      expect(gate.isArmed, isFalse);
    });

    test('a KeyUp whose KeyDown landed elsewhere is ignored, not acted on', () {
      final gate = BackPressGate();
      var fired = 0;

      expect(gate.handle(_up(LogicalKeyboardKey.escape), () => fired++), KeyEventResult.ignored);
      expect(gate.handle(_repeat(LogicalKeyboardKey.escape), () => fired++), KeyEventResult.ignored);
      expect(fired, 0);
    });

    test('keyDown phase acts on KeyDown and swallows the release silently', () {
      final gate = BackPressGate();
      var fired = 0;
      void onBack() => fired++;

      expect(gate.handle(_down(LogicalKeyboardKey.escape), onBack, phase: BackPhase.keyDown), KeyEventResult.handled);
      expect(fired, 1);
      expect(gate.handle(_up(LogicalKeyboardKey.escape), onBack, phase: BackPhase.keyDown), KeyEventResult.handled);
      expect(fired, 1);
    });

    test('a KeyDown while still armed is a fresh press (the previous release was swallowed off-app)', () {
      final gate = BackPressGate();
      var fired = 0;
      void onBack() => fired++;

      gate.handle(_down(LogicalKeyboardKey.goBack), onBack);
      // No KeyUp: a closing TV IME ate it.
      gate.handle(_down(LogicalKeyboardKey.goBack), onBack);
      gate.handle(_up(LogicalKeyboardKey.goBack), onBack);
      expect(fired, 1);
    });

    test('reset forgets an in-flight press so its release is ignored', () {
      final gate = BackPressGate();
      var fired = 0;

      gate.handle(_down(LogicalKeyboardKey.goBack), () => fired++);
      gate.reset();
      expect(gate.handle(_up(LogicalKeyboardKey.goBack), () => fired++), KeyEventResult.ignored);
      expect(fired, 0);
    });

    test('non-back keys are never consumed', () {
      final gate = BackPressGate();
      expect(gate.handle(_down(LogicalKeyboardKey.arrowLeft), () {}), KeyEventResult.ignored);
      expect(gate.handle(_up(LogicalKeyboardKey.enter), () {}), KeyEventResult.ignored);
    });

    test('backPhaseFor is keyDown on Apple TV and keyUp elsewhere', () {
      expect(backPhaseFor(_down(LogicalKeyboardKey.escape)), BackPhase.keyUp);
      TvDetectionService.debugSetAppleTVOverride(true);
      expect(backPhaseFor(_down(LogicalKeyboardKey.escape)), BackPhase.keyDown);
    });
  });

  group('BackKeyOwner', () {
    testWidgets('root dialogs cover a current nested profile route', (tester) async {
      final root = GlobalKey<NavigatorState>();
      late BuildContext profileContext;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: root,
          home: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) {
                profileContext = context;
                return const Scaffold(body: Text('Home'));
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(isCurrentRouteChain(profileContext), isTrue);
      unawaited(
        showDialog<void>(
          context: profileContext,
          builder: (_) => const AlertDialog(title: Text('Dialog')),
        ),
      );
      await tester.pumpAndSettle();
      expect(ModalRoute.of(profileContext)!.isCurrent, isTrue);
      expect(isCurrentRouteChain(profileContext), isFalse);
      root.currentState!.pop();
      await tester.pumpAndSettle();
      expect(isCurrentRouteChain(profileContext), isTrue);
    });

    testWidgets('system Back chooses only the innermost owner and falls through on a covered route', (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var innerBacks = 0;
      var outerBacks = 0;
      await tester.pumpWidget(
        InputModeTracker(
          child: MaterialApp(
            navigatorKey: navigator,
            home: BackKeyOwner(
              onBack: () => outerBacks++,
              child: BackKeyOwner(
                onBack: () => innerBacks++,
                child: Focus(focusNode: focus, autofocus: true, child: const SizedBox.expand()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.binding.handlePopRoute();
      expect(innerBacks, 1);
      expect(outerBacks, 0);

      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute(requestFocus: false, builder: (_) => const Scaffold(body: Text('Covered'))),
        ),
      );
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue, reason: 'exercise stale focus below the top route');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Covered'), findsNothing);
      expect(innerBacks, 1);
      expect(outerBacks, 0);
    });

    testWidgets('consumes Back for its subtree and lets other keys through', (tester) async {
      var backs = 0;
      final outer = <LogicalKeyboardKey>[];
      await tester.pumpWidget(
        Focus(
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent) outer.add(event.logicalKey);
            return KeyEventResult.ignored;
          },
          child: BackKeyOwner(
            onBack: () => backs++,
            child: const Focus(autofocus: true, child: SizedBox.expand()),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);

      expect(backs, 1);
      expect(outer, [LogicalKeyboardKey.arrowDown]);
    });
  });
}
