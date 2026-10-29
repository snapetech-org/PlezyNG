/// W3C Standard Gamepad button layout (17 buttons).
///
/// Button indices follow the W3C Gamepad specification mapping.
/// Enum values are declared in order so that [index] matches the W3C index.
/// See: https://w3c.github.io/gamepad/#remapping
enum GamepadButton {
  // index 0
  a,
  // index 1
  b,
  // index 2
  x,
  // index 3
  y,
  // index 4
  leftShoulder,
  // index 5
  rightShoulder,
  // index 6
  leftTrigger,
  // index 7
  rightTrigger,
  // index 8
  back,
  // index 9
  start,
  // index 10
  leftStickButton,
  // index 11
  rightStickButton,
  // index 12
  dpadUp,
  // index 13
  dpadDown,
  // index 14
  dpadLeft,
  // index 15
  dpadRight,
  // index 16
  guide;

  /// Returns the [GamepadButton] for the given W3C standard [index],
  /// or `null` if the index is out of range.
  static GamepadButton? fromIndex(int index) {
    if (index < 0 || index >= values.length) return null;
    return values[index];
  }
}
