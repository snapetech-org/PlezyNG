/// Standard gamepad axes (4 axes).
///
/// Axis indices follow the W3C Gamepad specification mapping.
/// Enum values are declared in order so that [index] matches the W3C index.
/// Values range from -1.0 to 1.0.
/// X axes: -1.0 = left, 1.0 = right.
/// Y axes: -1.0 = up, 1.0 = down.
enum GamepadAxis {
  // index 0
  leftStickX,
  // index 1
  leftStickY,
  // index 2
  rightStickX,
  // index 3
  rightStickY;

  /// Returns the [GamepadAxis] for the given W3C standard [index],
  /// or `null` if the index is out of range.
  static GamepadAxis? fromIndex(int index) {
    if (index < 0 || index >= values.length) return null;
    return values[index];
  }
}
