import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/hero_hub_section.dart';
import 'package:plezy/widgets/hub_section.dart';
import '../test_helpers/prefs.dart';
import 'appearance_fixtures.dart';

const appearanceViewports = <({String name, Size size, bool tv, double dpr})>[
  (name: 'folded phone', size: Size(280, 653), tv: false, dpr: 1),
  (name: 'small phone', size: Size(320, 568), tv: false, dpr: 1),
  (name: 'phone landscape', size: Size(568, 320), tv: false, dpr: 1),
  (name: 'phone', size: Size(390, 844), tv: false, dpr: 1),
  (name: 'iPhone landscape', size: Size(844, 390), tv: false, dpr: 1),
  (name: 'automotive', size: Size(800, 480), tv: false, dpr: 1),
  (name: 'tablet portrait', size: Size(600, 960), tv: false, dpr: 1),
  (name: 'tablet landscape', size: Size(1024, 768), tv: false, dpr: 1),
  (name: 'short desktop', size: Size(800, 480), tv: false, dpr: 1),
  (name: 'desktop', size: Size(1440, 900), tv: false, dpr: 1),
  (name: 'Windows desktop', size: Size(1280, 720), tv: false, dpr: 1),
  (name: 'macOS desktop', size: Size(1512, 982), tv: false, dpr: 1),
  (name: 'ultrawide', size: Size(3440, 1440), tv: false, dpr: 1),
  (name: 'super ultrawide', size: Size(5120, 1440), tv: false, dpr: 1),
  (name: '720p TV', size: Size(1280, 720), tv: true, dpr: 1),
  (name: '4K physical TV', size: Size(3840, 2160), tv: true, dpr: 2),
  (name: '4K logical TV', size: Size(3840, 2160), tv: true, dpr: 1),
];

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('ar');
  });
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });
  tearDown(() {
    TvDetectionService.debugReset();
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    LocaleSettings.setLocaleSync(AppLocale.en);
  });
  for (final viewport in appearanceViewports) {
    for (final scale in [1.0, 2.0]) {
      for (final direction in TextDirection.values) {
        testWidgets('${viewport.name} at ${scale}x $direction', (tester) async {
          tester.view.physicalSize = viewport.size;
          tester.view.devicePixelRatio = viewport.dpr;
          addTearDown(tester.view.reset);
          TvDetectionService.debugSetAppleTVOverride(viewport.tv);
          TvDetectionService.debugSetAutomotiveOverride(viewport.name == 'automotive');
          final desktop = viewport.name.contains('desktop') || viewport.name.contains('ultrawide');
          PlatformDetector.debugSetIsDesktopOSOverride(desktop);
          final platform = viewport.name.startsWith('iPhone')
              ? TargetPlatform.iOS
              : viewport.name.startsWith('Windows')
              ? TargetPlatform.windows
              : viewport.name.startsWith('macOS')
              ? TargetPlatform.macOS
              : desktop
              ? TargetPlatform.linux
              : TargetPlatform.android;
          await tester.runAsync(
            () => LocaleSettings.setLocale(direction == TextDirection.rtl ? AppLocale.ar : AppLocale.en),
          );
          for (final scene in AppearanceScene.values) {
            await tester.pumpWidget(
              appearanceApp(child: appearanceScene(scene), textScale: scale, direction: direction, platform: platform),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(tester.takeException(), isNull, reason: '${scene.name} at ${viewport.name}, $scale, $direction');
            if (scene == AppearanceScene.home) {
              final hero = tester.getRect(find.byType(HeroHubSection));
              final play = find.text(t.common.play).first;
              expect(
                tester.getRect(find.text(appearanceMovie.title!).first).top,
                greaterThanOrEqualTo(hero.top),
                reason: 'hero title must remain inside the artwork',
              );
              expect(
                tester.getRect(play).top,
                greaterThanOrEqualTo(hero.top),
                reason: 'hero action must stay inside its artwork',
              );
              await tester.scrollUntilVisible(find.byType(HubSection), 200, scrollable: find.byType(Scrollable).first);
              await tester.pump();
              expect(tester.takeException(), isNull, reason: 'shelf captions at ${viewport.name}, $scale');
            }
            if (scene == AppearanceScene.detail && !viewport.tv) {
              final strip = find.ancestor(of: find.text(t.mediaMenu.rate).first, matching: find.byType(Wrap)).first;
              for (final label in ['2026', 'PG', t.mediaMenu.rate]) {
                final texts = find.descendant(of: strip, matching: find.text(label));
                if (texts.evaluate().isEmpty) continue; // Narrow heroes may shed optional chips.
                final text = texts.first;
                final clip = find.ancestor(of: text, matching: find.byType(ClipRect)).first;
                final textBounds = tester.getRect(text);
                final clipBounds = tester.getRect(clip);
                expect(textBounds.top, greaterThanOrEqualTo(clipBounds.top - .01), reason: '$label top');
                expect(textBounds.bottom, lessThanOrEqualTo(clipBounds.bottom + .01), reason: '$label bottom');
              }
            }
            await tester.pumpWidget(const SizedBox());
            await tester.pump();
          }
        });
      }
    }
  }
}
