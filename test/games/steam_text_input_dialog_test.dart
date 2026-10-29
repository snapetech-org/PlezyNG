import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/games/steam_text_input_dialog.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/dialog_action_button.dart';

void main() {
  testWidgets('IME composition must commit before text can be sent', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.oled),
        home: const Scaffold(body: SteamTextInputDialog()),
      ),
    );
    await tester.pumpAndSettle();
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    DialogActionButton send() =>
        tester.widget<DialogActionButton>(find.widgetWithText(DialogActionButton, t.games.sendText));
    expect(send().onPressed, isNull);
    editable.controller.value = const TextEditingValue(
      text: '日本語',
      selection: TextSelection.collapsed(offset: 3),
      composing: TextRange(start: 0, end: 3),
    );
    await tester.pump();
    expect(send().onPressed, isNull);
    editable.controller.value = editable.controller.value.copyWith(composing: TextRange.empty);
    await tester.pump();
    expect(send().onPressed, isNotNull);
    editable.controller.text = '🙂' * 129;
    await tester.pump();
    expect(send().onPressed, isNull);
    expect(find.text(t.games.textInputInvalid), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
