import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/about_screen.dart';

import '../../test_helpers/theme.dart';

void main() {
  testWidgets('About opens the public feature comparison in an external browser', (tester) async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    PackageInfo.setMockInitialValues(
      appName: 'Pleazyng',
      packageName: 'com.plezy.test',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final launches = <Map<dynamic, dynamic>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'launch') launches.add(call.arguments as Map);
      return true;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(extensions: const [testMonoTokens]),
          home: const AboutScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final comparison = find.text('Feature comparison');
    await tester.ensureVisible(comparison);
    await tester.tap(comparison);
    await tester.pumpAndSettle();
    expect(launches, hasLength(1));
    expect(launches.single['url'], 'https://plezyng.app/features.html');
    expect(launches.single['useWebView'], isFalse);
    expect(tester.takeException(), isNull);
  });
}
