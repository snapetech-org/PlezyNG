import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/theme/palette_contrast.dart';
import 'package:plezy/theme/navigation_indicator_shape.dart';
import 'package:plezy/theme/theme_package.dart';
import 'package:plezy/widgets/video_controls/widgets/player_chrome_style.dart';

void main() {
  test('all default appearances retain readable text and controls', () {
    for (final palette in [MonoPalette.light, MonoPalette.dark, MonoPalette.oled]) {
      expect(PaletteContrastCheck.failing(palette), isEmpty);
      expect(MonoPalette.contrastRatio(palette.accent, palette.surface), greaterThanOrEqualTo(4.5));
      expect(monoTheme(palette).colorScheme.primary, palette.accent);
      expect(
        MonoPalette.contrastRatio(monoTheme(palette).colorScheme.error, palette.surface),
        greaterThanOrEqualTo(4.5),
      );
    }
    expect(MonoPalette.oled.bg, Colors.black);
  });

  test('navigation marker follows the leading edge in both text directions', () async {
    for (final direction in TextDirection.values) {
      final recorder = ui.PictureRecorder();
      const NavigationIndicatorShape(
        markerColor: Colors.teal,
      ).paint(Canvas(recorder), const Rect.fromLTWH(0, 0, 60, 40), textDirection: direction);
      final picture = recorder.endRecording();
      final image = await picture.toImage(60, 40);
      final pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final leading = direction == TextDirection.ltr ? 3 : 56;
      final trailing = direction == TextDirection.ltr ? 56 : 3;
      expect(pixels.getUint8((20 * 60 + leading) * 4 + 3), 255);
      expect(pixels.getUint8((20 * 60 + trailing) * 4 + 3), 0);
      image.dispose();
      picture.dispose();
    }
  });

  test('custom geometry reaches primary buttons and navigation indicators', () {
    final package = ThemePackage(id: 'compact', name: 'Compact', palette: MonoPalette.paper, radiusMd: 4);
    final theme = package.apply(monoTheme(package.palette));
    for (final shape in [
      theme.filledButtonTheme.style!.shape!.resolve({}),
      theme.elevatedButtonTheme.style!.shape!.resolve({}),
      theme.navigationBarTheme.indicatorShape,
      theme.navigationRailTheme.indicatorShape,
    ]) {
      expect((shape as RoundedRectangleBorder).borderRadius, BorderRadius.circular(4));
    }
  });

  test('player accents remain legible for light, dark and transparent custom colours', () {
    for (final color in [
      MonoPalette.light.accent,
      MonoPalette.dark.accent,
      Colors.black,
      Colors.transparent,
      Colors.red,
    ]) {
      final accent = PlayerChromeStyle.readableAccent(color);
      expect(MonoPalette.contrastRatio(accent, PlayerChromeStyle.surface), greaterThanOrEqualTo(4.5));
      expect(MonoPalette.contrastRatio(accent, Colors.black), greaterThanOrEqualTo(4.5));
    }
    expect(PlayerChromeStyle.readableAccent(MonoPalette.dark.accent), MonoPalette.dark.accent);
  });
}
