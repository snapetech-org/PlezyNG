import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/legacy_link_converter_screen.dart';

void main() {
  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));

  testWidgets('pastes, previews, and copies only after explicit confirmation', (tester) async {
    const upstreamLink = 'plezy://play?server=s1&id=i1&profile=Kids%20%26%20Teens';
    const canonicalLink = 'pleazyng://play?server=s1&id=i1&profile=Kids%20%26%20Teens';
    String? copiedText;
    final platform = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    platform.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return <String, Object?>{'text': upstreamLink};
      if (call.method == 'Clipboard.setData') {
        copiedText = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => platform.setMockMethodCallHandler(SystemChannels.platform, null));

    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: const LegacyLinkConverterScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('legacy-link-converter-paste')));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsNothing);

    await tester.tap(find.byKey(const ValueKey('legacy-link-converter-preview')));
    await tester.pumpAndSettle();
    expect(find.text(canonicalLink), findsOneWidget);
    expect(copiedText, isNull);

    await tester.tap(find.byKey(const ValueKey('legacy-link-converter-copy')));
    await tester.pumpAndSettle();
    expect(copiedText, canonicalLink);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows a clear error for unsupported routes and offers no output', (tester) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: const LegacyLinkConverterScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('legacy-link-converter-input')), 'plezy://unknown');
    await tester.tap(find.byKey(const ValueKey('legacy-link-converter-preview')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('legacy-link-converter-message')), findsOneWidget);
    expect(find.byKey(const ValueKey('legacy-link-converter-output')), findsNothing);
    expect(find.byKey(const ValueKey('legacy-link-converter-copy')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
