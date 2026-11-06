import 'package:flutter/material.dart';

/// Wrapper around [Icon] that centralizes our Material Symbols defaults.
/// Defaults: fill=1 (filled) and weight=700 (bold). Update [AppIconDefaults]
/// to tweak app-wide icon appearance from one place.
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.fill,
    this.weight,
    this.grade,
    this.opticalSize,
    this.shadows,
    this.semanticLabel,
    this.textDirection,
  });

  final IconData? icon;
  final double? size;
  final Color? color;
  final double? fill;
  final double? weight;
  final double? grade;
  final double? opticalSize;
  final List<Shadow>? shadows;
  final String? semanticLabel;
  final TextDirection? textDirection;

  @override
  Widget build(BuildContext context) {
    if (icon == null) return const SizedBox.shrink();
    final style = AppIconStyle.maybeOf(context);
    return Icon(
      icon,
      size: size,
      color: color,
      fill: fill ?? style?.fill ?? AppIconDefaults.fill,
      weight: weight ?? style?.weight ?? AppIconDefaults.weight,
      grade: grade ?? AppIconDefaults.grade,
      opticalSize: opticalSize ?? AppIconDefaults.opticalSize,
      shadows: shadows ?? AppIconDefaults.shadows,
      semanticLabel: semanticLabel,
      textDirection: textDirection,
    );
  }
}

/// Local defaults for utility icons; explicit selected/playback styles win.
class AppIconStyle extends InheritedWidget {
  const AppIconStyle({super.key, this.fill = 0, this.weight = 500, required super.child});

  final double fill;
  final double weight;

  static AppIconStyle? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppIconStyle>();

  @override
  bool updateShouldNotify(AppIconStyle oldWidget) => fill != oldWidget.fill || weight != oldWidget.weight;
}

/// Central place to adjust default Material Symbol variations.
class AppIconDefaults {
  static double fill = 1;
  static double weight = 700;
  static double? grade;
  static double? opticalSize;
  static Color? color;
  static List<Shadow>? shadows;

  static void update({
    double? fill,
    double? weight,
    double? grade,
    double? opticalSize,
    Color? color,
    List<Shadow>? shadows,
  }) {
    if (fill != null) AppIconDefaults.fill = fill;
    if (weight != null) AppIconDefaults.weight = weight;
    if (grade != null) AppIconDefaults.grade = grade;
    if (opticalSize != null) AppIconDefaults.opticalSize = opticalSize;
    if (color != null) AppIconDefaults.color = color;
    if (shadows != null) AppIconDefaults.shadows = shadows;
  }
}
