// Produces labeled interface previews, not device or store screenshots.
// This opt-in Flutter test harness lives outside test/ so normal runs do not render previews.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/overlay_sheet.dart';
import 'package:plezy/widgets/video_controls/sheets/subtitle_style_sheet.dart';

import '../../test/appearance/appearance_fixtures.dart';
import '../../test/test_helpers/prefs.dart';
import 'player_mockup.dart';

void main() {
  final output = Platform.environment['PLEAZYNG_PREVIEW_OUTPUT'];
  if (output == null) return; // Explicit opt-in; never rewrites assets in normal CI.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await initializeDateFormatting('en');
    await (FontLoader('Appearance Sans')..addFont(rootBundle.load('assets/go-noto-current-regular.ttf'))).load();
    for (final family in ['MaterialSymbolsRounded', 'MaterialSymbolsOutlined', 'MaterialSymbolsSharp']) {
      await (FontLoader(
        'packages/material_symbols_icons/$family',
      )..addFont(rootBundle.load('packages/material_symbols_icons/lib/fonts/$family.ttf'))).load();
    }
  });
  void preview({
    required String name,
    required String device,
    required Widget Function() scene,
    MonoPalette palette = MonoPalette.dark,
    bool landscape = false,
  }) {
    testWidgets('preview $name', (tester) async {
      resetSharedPreferencesForTest();
      SettingsService.resetForTesting();
      await SettingsService.getInstance();
      TvDetectionService.debugSetAppleTVOverride(device == 'tv');
      PlatformDetector.debugSetIsDesktopOSOverride(device == 'desktop');
      addTearDown(TvDetectionService.debugReset);
      addTearDown(() => PlatformDetector.debugSetIsDesktopOSOverride(null));
      tester.view.physicalSize = switch (device) {
        'tv' => const Size(1920, 1080),
        'phone' => landscape ? const Size(2400, 1080) : const Size(1080, 2400),
        'tablet' => const Size(1600, 2560),
        _ => const Size(1920, 1200),
      };
      tester.view.devicePixelRatio = device == 'phone'
          ? 3
          : device == 'tv' || device == 'tablet'
          ? 2
          : 1.5;
      addTearDown(tester.view.reset);
      const capture = Key('store-preview');
      await tester.pumpWidget(
        appearanceApp(
          loadFonts: true,
          palette: palette,
          platform: device == 'desktop' ? TargetPlatform.linux : TargetPlatform.android,
          child: RepaintBoundary(key: capture, child: scene()),
        ),
      );
      await tester.pump();
      await tester.runAsync(() async {
        final context = tester.element(find.byKey(capture));
        for (final image in tester.widgetList<Image>(find.byType(Image))) {
          await precacheImage(image.image, context);
        }
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        final directory = Directory(output)..createSync(recursive: true);
        await File('${directory.path}/$name-preview.png').writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final device in ['tv', 'phone', 'tablet', 'desktop']) {
    for (final scene in [
      AppearanceScene.login,
      AppearanceScene.home,
      AppearanceScene.detail,
      AppearanceScene.settings,
    ]) {
      preview(name: '$device-${scene.name}', device: device, scene: () => appearanceScene(scene));
    }
  }

  for (final entry in {'dark': MonoPalette.dark, 'light': MonoPalette.light, 'oled': MonoPalette.oled}.entries) {
    preview(
      name: 'desktop-appearance-${entry.key}',
      device: 'desktop',
      scene: () => appearanceScene(AppearanceScene.settings),
      palette: entry.value,
    );
    preview(
      name: 'desktop-subtitle-style-${entry.key}',
      device: 'desktop',
      scene: () => OverlaySheetHost(
        child: Scaffold(
          body: Center(
            child: SizedBox(width: 700, child: InPlayerSubtitleStyleSheet(player: AppearanceFakePlayer())),
          ),
        ),
      ),
      palette: entry.value,
    );
  }
  for (final device in ['desktop', 'phone']) {
    preview(name: '$device-player-mockup', device: device, landscape: true, scene: () => const PlayerMockup());
  }
}
