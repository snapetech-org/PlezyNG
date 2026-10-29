import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/games/steam_touch_layout.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/games/steam_touch_controls.dart';
import 'package:plezy/screens/games/steam_touch_layout_dialog.dart';
import 'package:plezy/theme/mono_theme.dart';

void main() {
  test('default geometry and swapped sides preserve non-overlapping hit targets', () {
    for (final size in [const Size(360, 352), const Size(400, 800), const Size(640, 216), const Size(1920, 1080)]) {
      for (final swap in [false, true]) {
        final positions = SteamTouchLayout.defaults(size, swapSides: swap);
        expect(SteamTouchLayout.valid(positions, size), isTrue, reason: '$size swap=$swap');
        for (final key in SteamTouchLayout.controls) {
          final position = SteamTouchLayout.position(positions[key]!, size, key);
          expect(position.dx, greaterThanOrEqualTo(7.99));
          expect(position.dy, greaterThanOrEqualTo(7.99));
          expect(position.dx + SteamTouchLayout.extent(key), lessThanOrEqualTo(size.width - 7.99));
        }
      }
    }
  });
  test('saved layouts are bounded, independent by orientation, and safely adapt to resize', () {
    const size = Size(800, 500);
    final positions = SteamTouchLayout.defaults(size);
    positions['leftStick'] = SteamTouchLayout.normalize(const Offset(350, 140), size, 'leftStick');
    final layout = SteamTouchLayout().replace(size, positions);
    expect(SteamTouchLayout.restore(layout.encode()).wide, layout.wide);
    expect(layout.compact, isEmpty);
    final overlap = {...positions, 'a': positions['b']!};
    expect(() => layout.replace(size, overlap), throwsFormatException);
    for (final malformed in [
      'x' * 8193,
      jsonEncode({
        'version': 1,
        'wide': {
          'a': [2, 0],
        },
        'compact': {},
      }),
      jsonEncode({
        'version': 1,
        'wide': {
          'unknown': [0, 0],
        },
        'compact': {},
      }),
    ]) {
      expect(SteamTouchLayout.restore(malformed).wide, isEmpty);
    }
    final tiny = layout.resolve(const Size(640, 216));
    expect(SteamTouchLayout.valid(tiny, const Size(640, 216)), isTrue);
  });

  testWidgets('drag editing saves a real layout and position controls work at large text sizes', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SteamTouchLayout? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.oled),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                saved = await showDialog<SteamTouchLayout>(
                  context: context,
                  builder: (_) => SteamTouchLayoutDialog(initial: SteamTouchLayout()),
                );
              },
              child: const Text('Edit'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    final stick = find.byKey(const ValueKey('edit-leftStick'));
    await tester.drag(stick, const Offset(180, -100));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Position controls'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(saved, isNotNull);
    expect(saved!.wide, isNotEmpty);
  });

  testWidgets('position sliders name their control and axis and support semantic adjustment', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(MaterialApp(home: SteamTouchLayoutDialog(initial: SteamTouchLayout())));
      await tester.tap(find.byTooltip(t.games.touchLayoutPosition));
      await tester.pumpAndSettle();
      final horizontal = find.bySemanticsLabel(
        '${steamTouchControlLabel('leftStick')}, ${t.games.touchLayoutHorizontal}',
      );
      final vertical = find.bySemanticsLabel('${steamTouchControlLabel('leftStick')}, ${t.games.touchLayoutVertical}');
      expect(horizontal, findsOneWidget);
      expect(vertical, findsOneWidget);
      final node = tester.getSemantics(horizontal);
      expect(node.getSemanticsData().hasAction(SemanticsAction.increase), isTrue);
      final previousValue = node.getSemanticsData().value;
      expect(previousValue, isNotEmpty);
      final previous = tester.getTopLeft(find.byKey(const ValueKey('edit-leftStick')));
      tester.binding.rootPipelineOwner.visitChildren(
        (owner) => owner.semanticsOwner?.performAction(node.id, SemanticsAction.increase),
      );
      await tester.pumpAndSettle();
      final adjusted = tester.getTopLeft(find.byKey(const ValueKey('edit-leftStick')));
      expect(adjusted.dx, greaterThan(previous.dx));
      expect(adjusted.dy, previous.dy);
      expect(tester.getSemantics(horizontal).getSemanticsData().value, isNot(previousValue));
      tester.binding.rootPipelineOwner.visitChildren(
        (owner) => owner.semanticsOwner?.performAction(node.id, SemanticsAction.decrease),
      );
      await tester.pumpAndSettle();
      final decreased = tester.getTopLeft(find.byKey(const ValueKey('edit-leftStick')));
      expect(decreased.dx, lessThan(adjusted.dx));
      expect(decreased.dy, previous.dy);
    } finally {
      semantics.dispose();
    }
  });
}
