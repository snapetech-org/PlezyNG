import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/dpad_navigator.dart';
import 'package:plezy/focus/focusable_wrapper.dart';
import 'package:plezy/widgets/focusable_list_tile.dart';
import 'package:plezy/widgets/focusable_tab_chip.dart';

void main() {
  tearDown(() {
    SelectKeyUpSuppressor.clearSuppression();
  });

  Widget control(String kind, FocusNode node, VoidCallback tap, VoidCallback hold) => switch (kind) {
    'row' => FocusableListTile(focusNode: node, title: const Text('Item'), onTap: tap, onLongPress: hold),
    'chip' => FocusableTabChip(focusNode: node, label: 'Item', isSelected: false, onSelect: tap, onLongPress: hold),
    _ => FocusableWrapper(
      focusNode: node,
      onSelect: tap,
      onLongPress: hold,
      enableLongPress: true,
      child: const SizedBox(width: 100, height: 40, child: Text('Item')),
    ),
  };

  // TV engines report Android, iOS (tvOS) or Linux (webOS/Tizen) to Flutter.
  // Use the complete Android test translation map to inject logical keys.
  // These tests qualify the Flutter key contract, not physical remote firmware.
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    for (final kind in ['row', 'chip', 'card']) {
      testWidgets('$platform $kind consumes menu repeats and supports every SELECT mapping', (tester) async {
        final node = FocusNode();
        addTearDown(node.dispose);
        var taps = 0;
        var holds = 0;
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: control(kind, node, () => taps++, () => holds++))));
        node.requestFocus();
        await tester.pump();
        for (final key in [
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.numpadEnter,
          LogicalKeyboardKey.select,
          LogicalKeyboardKey.gameButtonA,
        ]) {
          final oldTaps = taps;
          final oldHolds = holds;
          await tester.sendKeyDownEvent(key, platform: 'android');
          await tester.pump(const Duration(milliseconds: 100));
          await tester.sendKeyUpEvent(key, platform: 'android');
          expect(taps, oldTaps + 1);
          await tester.sendKeyDownEvent(key, platform: 'android');
          await tester.pump(const Duration(milliseconds: 600));
          await tester.sendKeyRepeatEvent(key, platform: 'android');
          await tester.sendKeyUpEvent(key, platform: 'android');
          expect(holds, oldHolds + 1);
          expect(taps, oldTaps + 1);
        }
        for (final key in [LogicalKeyboardKey.contextMenu, LogicalKeyboardKey.gameButtonX]) {
          final oldHolds = holds;
          await tester.sendKeyDownEvent(key, platform: 'android');
          await tester.sendKeyRepeatEvent(key, platform: 'android');
          await tester.sendKeyRepeatEvent(key, platform: 'android');
          await tester.sendKeyUpEvent(key, platform: 'android');
          expect(holds, oldHolds + 1);
        }
      }, variant: TargetPlatformVariant({platform}));
    }
  }
}
