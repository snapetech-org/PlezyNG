import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Rounded selection with a short leading marker, mirrored in RTL layouts.
class NavigationIndicatorShape extends RoundedRectangleBorder {
  const NavigationIndicatorShape({
    required this.markerColor,
    super.side,
    super.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  final Color markerColor;

  @override
  NavigationIndicatorShape copyWith({BorderSide? side, BorderRadiusGeometry? borderRadius, Color? markerColor}) =>
      NavigationIndicatorShape(
        markerColor: markerColor ?? this.markerColor,
        side: side ?? this.side,
        borderRadius: borderRadius ?? this.borderRadius,
      );

  @override
  ShapeBorder scale(double t) => copyWith(side: side.scale(t), borderRadius: borderRadius * t);

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => a is NavigationIndicatorShape
      ? NavigationIndicatorShape(
          markerColor: Color.lerp(a.markerColor, markerColor, t)!,
          side: BorderSide.lerp(a.side, side, t),
          borderRadius: BorderRadiusGeometry.lerp(a.borderRadius, borderRadius, t)!,
        )
      : super.lerpFrom(a, t);

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) =>
      b is NavigationIndicatorShape ? b.lerpFrom(this, t) : super.lerpTo(b, t);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    super.paint(canvas, rect, textDirection: textDirection);
    if (markerColor.a == 0 || rect.width < 8 || rect.height < 12) return;
    final height = math.min(18.0, rect.height - 12);
    final left = textDirection == TextDirection.rtl ? rect.right - 5 : rect.left + 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(left, rect.center.dy - height / 2, 3, height), const Radius.circular(1.5)),
      Paint()..color = markerColor,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NavigationIndicatorShape &&
      other.markerColor == markerColor &&
      other.side == side &&
      other.borderRadius == borderRadius;

  @override
  int get hashCode => Object.hash(markerColor, side, borderRadius);
}
