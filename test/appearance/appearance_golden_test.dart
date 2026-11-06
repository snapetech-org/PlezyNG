import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import '../test_helpers/prefs.dart';
import 'appearance_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('ar');
    final text = FontLoader('Appearance Sans')..addFont(rootBundle.load('assets/go-noto-current-regular.ttf'));
    await text.load();
    for (final family in ['MaterialSymbolsRounded', 'MaterialSymbolsOutlined', 'MaterialSymbolsSharp']) {
      await (FontLoader(
        'packages/material_symbols_icons/$family',
      )..addFont(rootBundle.load('packages/material_symbols_icons/lib/fonts/$family.ttf'))).load();
    }
  });
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    TvDetectionService.debugSetAppleTVOverride(false);
  });
  tearDown(() {
    TvDetectionService.debugReset();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  final palettes = {'light': MonoPalette.light, 'dark': MonoPalette.dark, 'oled': MonoPalette.oled};
  for (final palette in palettes.entries) {
    for (final compact in [false, true]) {
      final variant = compact ? 'phone_rtl_200' : 'desktop';
      for (final scene in [
        AppearanceScene.home,
        AppearanceScene.detail,
        AppearanceScene.settings,
        AppearanceScene.player,
      ]) {
        testWidgets('${scene.name} ${palette.key} $variant', (tester) async {
          tester.view.physicalSize = compact ? const Size(390, 844) : const Size(1280, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.runAsync(() => LocaleSettings.setLocale(compact ? AppLocale.ar : AppLocale.en));
          const capture = Key('appearance_capture');
          await tester.pumpWidget(
            appearanceApp(
              palette: palette.value,
              textScale: compact ? 2 : 1,
              direction: compact ? TextDirection.rtl : TextDirection.ltr,
              loadFonts: true,
              platform: compact ? TargetPlatform.android : TargetPlatform.linux,
              child: RepaintBoundary(key: capture, child: appearanceScene(scene)),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byKey(capture),
            matchesGoldenFile('goldens/${scene.name}_${palette.key}_$variant.png'),
          );
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        });
      }
    }
  }
}
