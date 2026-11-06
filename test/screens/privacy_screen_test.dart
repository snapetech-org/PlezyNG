import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/auth_screen.dart';
import 'package:plezy/screens/settings/privacy_screen.dart';

void main() {
  testWidgets('privacy is readable offline before connecting an account', (tester) async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await tester.pumpWidget(TranslationProvider(child: const MaterialApp(home: AuthScreen(initializeServices: false))));
    await tester.pumpAndSettle();
    final link = find.widgetWithText(TextButton, t.about.privacyPolicy);
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(find.byType(PrivacyScreen), findsOneWidget);
    expect(find.textContaining('Disconnecting accounts and deleting data'), findsOneWidget);
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final beforeScroll = scrollable.position.pixels;
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(beforeScroll));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Korean locale loads the bundled Korean notice', (tester) async {
    await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.ko));
    addTearDown(() => LocaleSettings.setLocaleSync(AppLocale.en));
    await tester.pumpWidget(TranslationProvider(child: const MaterialApp(home: PrivacyScreen())));
    await tester.pumpAndSettle();
    expect(find.textContaining('계정 연결 해제 및 데이터 삭제'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
