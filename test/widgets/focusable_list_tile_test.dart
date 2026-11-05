import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/focus/dpad_navigator.dart';
import 'package:plezy/widgets/focusable_list_tile.dart';

void main() {
  tearDown(SelectKeyUpSuppressor.clearSuppression);

  for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.select, LogicalKeyboardKey.gameButtonA]) {
    testWidgets('list tile distinguishes tap and held $key without repeating', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      var taps = 0;
      var holds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FocusableListTile(
              focusNode: node,
              title: const Text('Item'),
              onTap: () => taps++,
              onLongPress: () => holds++,
            ),
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(key);
      await tester.pump(const Duration(milliseconds: 200));
      expect(taps, 0);
      await tester.sendKeyUpEvent(key);
      expect(taps, 1);
      expect(holds, 0);
      await tester.sendKeyDownEvent(key);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.sendKeyRepeatEvent(key);
      await tester.pump(const Duration(milliseconds: 250));
      expect(holds, 1);
      await tester.sendKeyRepeatEvent(key);
      await tester.sendKeyUpEvent(key);
      await tester.pump(const Duration(seconds: 1));
      expect(holds, 1);
      expect(taps, 1);
      await tester.tap(find.text('Item'));
      expect(taps, 2);
    });
  }

  testWidgets('focus loss and disabling a row cancel pending holds', (tester) async {
    final node = FocusNode();
    final other = FocusNode();
    addTearDown(node.dispose);
    addTearDown(other.dispose);
    var actions = 0;
    Widget content(bool enabled) => MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            FocusableListTile(
              focusNode: node,
              enabled: enabled,
              title: const Text('Item'),
              onTap: () => actions++,
              onLongPress: () => actions++,
            ),
            TextButton(focusNode: other, onPressed: () {}, child: const Text('Other')),
          ],
        ),
      ),
    );
    await tester.pumpWidget(content(true));
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 200));
    other.requestFocus();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    expect(actions, 0);
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pumpWidget(content(false));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    expect(actions, 0);
  });

  testWidgets('releasing a held select cannot activate the newly opened dialog', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    var accidentalSelections = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FocusableListTile(
              focusNode: node,
              title: const Text('Item'),
              onTap: () => accidentalSelections++,
              onLongPress: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  actions: [
                    TextButton(autofocus: true, onPressed: () => accidentalSelections++, child: const Text('Delete')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(accidentalSelections, 0);
  });

  testWidgets('menu key opens a row context action once', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    var holds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusableListTile(focusNode: node, title: const Text('Item'), onLongPress: () => holds++),
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    expect(holds, 1);
  });

  testWidgets('switch tile toggles once from SELECT', (tester) async {
    final focusNode = FocusNode(debugLabel: 'switch');
    addTearDown(focusNode.dispose);
    var value = false;
    var changes = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => FocusableSwitchListTile(
              focusNode: focusNode,
              value: value,
              title: const Text('Switch'),
              onChanged: (next) {
                changes++;
                setState(() => value = next);
              },
            ),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(value, isTrue);
    expect(changes, 1);
  });

  testWidgets('checkbox tile toggles once from SELECT', (tester) async {
    final focusNode = FocusNode(debugLabel: 'checkbox');
    addTearDown(focusNode.dispose);
    var value = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => FocusableCheckboxListTile(
              focusNode: focusNode,
              value: value,
              title: const Text('Checkbox'),
              onChanged: (next) => setState(() => value = next ?? false),
            ),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(value, isTrue);
  });

  testWidgets('disabled switch tile cannot be focused or activated', (tester) async {
    final focusNode = FocusNode(debugLabel: 'disabled switch');
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusableSwitchListTile(
            focusNode: focusNode,
            value: false,
            title: const Text('Disabled'),
            onChanged: null,
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    expect(focusNode.hasFocus, isFalse);
  });

  Widget buildScrollableTiles({required ScrollController controller, required FocusNode bottomNode}) {
    return InputModeTracker(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: controller,
            child: Column(
              children: [
                for (var i = 0; i < 30; i++) const SizedBox(height: 56, width: 100),
                FocusableListTile(focusNode: bottomNode, title: const Text('Target'), onTap: () {}),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('pointer-mode focus gain does not reveal the tile', (tester) async {
    final bottomNode = FocusNode(debugLabel: 'tile');
    final controller = ScrollController();
    addTearDown(bottomNode.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(buildScrollableTiles(controller: controller, bottomNode: bottomNode));

    // Programmatic focus without a keyboard session (e.g. a context menu
    // restoring focus on close, issue #2031) must not move the viewport.
    bottomNode.requestFocus();
    await tester.pumpAndSettle();

    expect(bottomNode.hasFocus, isTrue);
    expect(controller.offset, 0);
  });

  testWidgets('keyboard-mode focus gain centers the tile', (tester) async {
    final bottomNode = FocusNode(debugLabel: 'tile');
    final controller = ScrollController();
    addTearDown(bottomNode.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(buildScrollableTiles(controller: controller, bottomNode: bottomNode));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    bottomNode.requestFocus();
    await tester.pumpAndSettle();

    expect(bottomNode.hasFocus, isTrue);
    expect(controller.offset, greaterThan(0));
  });
}
