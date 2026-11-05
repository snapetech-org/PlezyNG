import 'package:flutter/material.dart';

import '../../../theme/mono_theme.dart';

/// Player overlays stay dark regardless of the library's appearance.
abstract final class PlayerChromeStyle {
  static const surface = Color(0xFF141E29);
  static const foreground = Color(0xFFEDF3FA);

  /// Light/custom theme accents may need lifting to read over the player.
  static Color accent(BuildContext context) => readableAccent(Theme.of(context).colorScheme.primary);

  static Color readableAccent(Color color) {
    final opaque = Color.alphaBlend(color, surface);
    for (var step = 0; step <= 10; step++) {
      final candidate = Color.lerp(opaque, Colors.white, step / 10)!;
      if (MonoPalette.contrastRatio(candidate, surface) >= 4.5) return candidate;
    }
    return Colors.white;
  }
}
