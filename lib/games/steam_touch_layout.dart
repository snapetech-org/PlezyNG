import 'dart:convert';

import 'package:flutter/painting.dart';

/// Separate compact/wide layouts keep rotation from stacking controls. Values
/// are normalized over each control's available travel, preserving hit sizes.
class SteamTouchLayout {
  SteamTouchLayout({Map<String, Offset> wide = const {}, Map<String, Offset> compact = const {}})
    : wide = Map.unmodifiable(wide),
      compact = Map.unmodifiable(compact);
  final Map<String, Offset> wide, compact;
  static const controls = [
    'leftStick',
    'rightStick',
    'a',
    'b',
    'x',
    'y',
    'dpadUp',
    'dpadDown',
    'dpadLeft',
    'dpadRight',
    'leftBumper',
    'leftTrigger',
    'rightTrigger',
    'rightBumper',
    'select',
    'mode',
    'start',
  ];
  static double extent(String key) => key.endsWith('Stick') ? 88 : 48;
  static bool fits(Size size) => size.width >= 360 && size.height >= (size.width >= 640 ? 216 : 352);
  static Offset position(Offset normalized, Size size, String key) => Offset(
    8 + normalized.dx.clamp(0.0, 1.0) * (size.width - 16 - extent(key)),
    8 + normalized.dy.clamp(0.0, 1.0) * (size.height - 16 - extent(key)),
  );
  static Offset normalize(Offset position, Size size, String key) => Offset(
    ((position.dx - 8) / (size.width - 16 - extent(key))).clamp(0.0, 1.0),
    ((position.dy - 8) / (size.height - 16 - extent(key))).clamp(0.0, 1.0),
  );
  static Map<String, Offset> defaults(Size size, {bool swapSides = false}) {
    final wide = size.width >= 640;
    final groupWidth = wide ? 240.0 : 144.0;
    final left = swapSides ? size.width - 8 - groupWidth : 8.0;
    final right = swapSides ? 8.0 : size.width - 8 - groupWidth;
    final top = size.height - (wide ? 152 : 288);
    final positions = <String, Offset>{};
    void cross(double x, double y, List<String> names) {
      for (final entry in [Offset(48, 0), Offset(0, 48), Offset(96, 48), Offset(48, 96)].asMap().entries) {
        positions[names[entry.key]] = Offset(x, y) + entry.value;
      }
    }

    cross(left, top + (wide ? 0 : 136), ['dpadUp', 'dpadLeft', 'dpadRight', 'dpadDown']);
    cross(right + (wide ? 96 : 0), top + (wide ? 0 : 48), ['y', 'x', 'b', 'a']);
    positions['leftBumper'] = Offset(left + (wide ? 144 : 24), top + (wide ? 4 : 0));
    positions['leftTrigger'] = positions['leftBumper']! + const Offset(48, 0);
    positions['rightTrigger'] = Offset(right + (wide ? 0 : 24), top + (wide ? 4 : 0));
    positions['rightBumper'] = positions['rightTrigger']! + const Offset(48, 0);
    positions['leftStick'] = Offset(left + (wide ? 148 : 28), top + (wide ? 52 : 48));
    positions['rightStick'] = Offset(right + (wide ? 4 : 28), top + (wide ? 52 : 192));
    for (var i = 0; i < 3; i++) {
      positions[['select', 'mode', 'start'][i]] = Offset(size.width / 2 - 72 + 48 * i, 8);
    }
    return positions.map((key, value) => MapEntry(key, normalize(value, size, key)));
  }

  Map<String, Offset> resolve(Size size, {bool swapSides = false}) {
    final saved = size.width >= 640 ? wide : compact;
    final fallback = defaults(size, swapSides: swapSides);
    final candidate = {...fallback, ...saved};
    return valid(candidate, size) ? candidate : fallback;
  }

  static bool valid(Map<String, Offset> values, Size size) {
    if (!fits(size) || values.length != controls.length || !controls.every(values.containsKey)) return false;
    final rects = <Rect>[];
    for (final key in controls) {
      final value = values[key]!;
      if (!value.dx.isFinite || !value.dy.isFinite || value.dx < 0 || value.dx > 1 || value.dy < 0 || value.dy > 1) {
        return false;
      }
      final rect = position(value, size, key) & Size.square(extent(key));
      // Half-pixel tolerance avoids floating point rejection of touching edges.
      if (rects.any((other) => other.deflate(.5).overlaps(rect.deflate(.5)))) return false;
      rects.add(rect);
    }
    return true;
  }

  SteamTouchLayout replace(Size size, Map<String, Offset> positions) {
    if (!valid(positions, size)) throw const FormatException('Invalid touch layout');
    return size.width >= 640
        ? SteamTouchLayout(wide: positions, compact: compact)
        : SteamTouchLayout(wide: wide, compact: positions);
  }

  String encode() => jsonEncode({'version': 1, 'wide': _encode(wide), 'compact': _encode(compact)});
  static Map<String, List<double>> _encode(Map<String, Offset> value) =>
      value.map((key, point) => MapEntry(key, [point.dx, point.dy]));
  static SteamTouchLayout restore(String? value) {
    if (value == null || value.length > 8192) return SteamTouchLayout();
    try {
      final data = jsonDecode(value);
      if (data is! Map || data['version'] != 1) return SteamTouchLayout();
      Map<String, Offset> read(Object? raw) {
        if (raw is! Map || raw.length > controls.length) throw const FormatException();
        final result = <String, Offset>{};
        for (final key in raw.keys) {
          final point = raw[key];
          if (!controls.contains(key) ||
              point is! List ||
              point.length != 2 ||
              point.any((v) => v is! num || !v.isFinite || v < 0 || v > 1)) {
            throw const FormatException();
          }
          result[key as String] = Offset((point[0] as num).toDouble(), (point[1] as num).toDouble());
        }
        return result;
      }

      return SteamTouchLayout(wide: read(data['wide']), compact: read(data['compact']));
    } catch (_) {
      return SteamTouchLayout();
    }
  }
}
