import 'dart:convert';

import 'package:flutter/material.dart';

import 'mono_theme.dart';
import 'mono_tokens.dart';
import 'navigation_indicator_shape.dart';

enum ThemeNavigation { adaptive, sidebar, bottom }

@immutable
final class ThemeLayout extends ThemeExtension<ThemeLayout> {
  const ThemeLayout({this.navigation = ThemeNavigation.adaptive});
  final ThemeNavigation navigation;
  @override
  ThemeLayout copyWith({ThemeNavigation? navigation}) => ThemeLayout(navigation: navigation ?? this.navigation);
  @override
  ThemeLayout lerp(covariant ThemeLayout? other, double t) => t < 0.5 ? this : other ?? this;
}

/// Declarative native styles, with bounded geometry and no executable assets.
/// Reader HTML stylesheets are owned by the reader and never enter this schema.
@immutable
final class ThemePackage {
  const ThemePackage({
    required this.id,
    required this.name,
    required this.palette,
    this.radiusSm = 8,
    this.radiusMd = 12,
    this.radiusLg = 20,
    this.radiusXs = 5,
    this.space = 12,
    this.groupGap = 2,
    this.textScale = 1,
    this.navigation = ThemeNavigation.adaptive,
  });
  static const maximumBytes = 128 * 1024;
  final String id, name;
  final MonoPalette palette;
  final double radiusSm, radiusMd, radiusLg, radiusXs, space, groupGap, textScale;
  final ThemeNavigation navigation;

  factory ThemePackage.decode(String raw) {
    if (raw.length > maximumBytes || utf8.encode(raw).length > maximumBytes) {
      throw const FormatException('Theme package exceeds 128 KiB');
    }
    return ThemePackage.fromJson(jsonDecode(raw));
  }

  factory ThemePackage.fromJson(Object? value) {
    if (value is! Map || value['schemaVersion'] != 1) {
      throw const FormatException('Unsupported theme schema');
    }
    void keys(Map map, Set<String> allowed) {
      if (map.keys.any((key) => !allowed.contains(key))) {
        throw const FormatException('Unsupported theme token');
      }
    }

    keys(value, {'schemaVersion', 'id', 'name', 'palette', 'geometry', 'typography', 'layout'});
    final id = value['id'], name = value['name'];
    if (id is! String ||
        !RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$').hasMatch(id) ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 80 ||
        name.contains(RegExp(r'[\x00-\x1f]'))) {
      throw const FormatException('Invalid theme identity');
    }
    Map section(String key, Set<String> allowed) {
      final data = value[key] ?? const {};
      if (data is! Map) {
        throw const FormatException('Invalid theme section');
      }
      keys(data, allowed);
      return data;
    }

    final geometry = section('geometry', {'radiusSm', 'radiusMd', 'radiusLg', 'radiusXs', 'space', 'groupGap'});
    final typography = section('typography', {'scale'});
    final layout = section('layout', {'navigation'});
    double number(Map map, String key, double fallback, double minimum, double maximum) {
      final n = map[key] ?? fallback;
      if (n is! num || !n.isFinite || n < minimum || n > maximum) {
        throw FormatException('Invalid theme $key');
      }
      return n.toDouble();
    }

    final nav = layout['navigation'] ?? 'adaptive';
    final navigation = ThemeNavigation.values.where((value) => value.name == nav).firstOrNull;
    if (navigation == null) {
      throw const FormatException('Unsupported navigation layout');
    }
    return ThemePackage(
      id: id,
      name: name.trim(),
      palette: MonoPalette.fromJson(value['palette']),
      radiusSm: number(geometry, 'radiusSm', 8, 0, 40),
      radiusMd: number(geometry, 'radiusMd', 12, 0, 40),
      radiusLg: number(geometry, 'radiusLg', 20, 0, 48),
      radiusXs: number(geometry, 'radiusXs', 5, 0, 24),
      space: number(geometry, 'space', 12, 8, 24),
      groupGap: number(geometry, 'groupGap', 2, 0, 12),
      textScale: number(typography, 'scale', 1, 0.9, 1.3),
      navigation: navigation,
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'name': name,
    'palette': palette.toJson(),
    'geometry': {
      'radiusSm': radiusSm,
      'radiusMd': radiusMd,
      'radiusLg': radiusLg,
      'radiusXs': radiusXs,
      'space': space,
      'groupGap': groupGap,
    },
    'typography': {'scale': textScale},
    'layout': {'navigation': navigation.name},
  };
  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  ThemeData apply(ThemeData base) {
    final tokens = base.extension<MonoTokens>()!;
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd));
    // Sparse text themes inherit unspecified sizes later in Flutter. Scale
    // only declared sizes so a package does not assert on those inherited styles.
    TextStyle? scaled(TextStyle? style) {
      if (style == null || style.fontSize == null) return style;
      return style.apply(fontSizeFactor: textScale);
    }

    final text = base.textTheme;
    return base.copyWith(
      textTheme: text.copyWith(
        displayLarge: scaled(text.displayLarge),
        displayMedium: scaled(text.displayMedium),
        displaySmall: scaled(text.displaySmall),
        headlineLarge: scaled(text.headlineLarge),
        headlineMedium: scaled(text.headlineMedium),
        headlineSmall: scaled(text.headlineSmall),
        titleLarge: scaled(text.titleLarge),
        titleMedium: scaled(text.titleMedium),
        titleSmall: scaled(text.titleSmall),
        bodyLarge: scaled(text.bodyLarge),
        bodyMedium: scaled(text.bodyMedium),
        bodySmall: scaled(text.bodySmall),
        labelLarge: scaled(text.labelLarge),
        labelMedium: scaled(text.labelMedium),
        labelSmall: scaled(text.labelSmall),
      ),
      cardTheme: base.cardTheme.copyWith(shape: shape),
      filledButtonTheme: FilledButtonThemeData(
        style: base.filledButtonTheme.style?.copyWith(shape: WidgetStatePropertyAll(shape)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: base.elevatedButtonTheme.style?.copyWith(shape: WidgetStatePropertyAll(shape)),
      ),
      navigationBarTheme: base.navigationBarTheme.copyWith(
        indicatorShape: NavigationIndicatorShape(
          markerColor: palette.accent,
          borderRadius: BorderRadius.circular(radiusMd),
        ),
      ),
      navigationRailTheme: base.navigationRailTheme.copyWith(
        indicatorShape: NavigationIndicatorShape(
          markerColor: palette.accent,
          borderRadius: BorderRadius.circular(radiusMd),
        ),
      ),
      dialogTheme: base.dialogTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusLg)),
      ),
      listTileTheme: base.listTileTheme.copyWith(
        contentPadding: EdgeInsetsDirectional.symmetric(horizontal: space, vertical: 4),
      ),
      extensions: [
        for (final extension in base.extensions.values)
          if (extension is! MonoTokens && extension is! ThemeLayout) extension,
        tokens.copyWith(
          radiusSm: radiusSm,
          radiusMd: radiusMd,
          radiusLg: radiusLg,
          radiusXs: radiusXs,
          space: space,
          groupGap: groupGap,
        ),
        ThemeLayout(navigation: navigation),
      ],
    );
  }
}
