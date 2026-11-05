import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/games/steam_input_profile.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/games/steam_input_dialog.dart';

void main() {
  testWidgets('layout editor scrolls at large text and preserves a failed draft', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var attempted = 0;
    final profile = SteamInputProfile.defaults().change(0, 1, 1);
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.oled),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(480, 800), textScaler: TextScaler.linear(1.5)),
          child: Scaffold(
            body: SteamInputDialog(
              initial: profile,
              players: 4,
              isCurrent: () => true,
              apply: (draft) async {
                attempted++;
                expect(draft.seats[0][1], 1);
                throw StateError('native layout rejected');
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(FilledButton, t.common.save));
    await tester.pumpAndSettle();
    expect(attempted, 1);
    expect(find.text(t.games.controllerLayoutFailed), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
