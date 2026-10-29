import 'gamepad_axis.dart';
import 'gamepad_button.dart';
import 'gamepad_info.dart';

/// Base class for all gamepad events.
sealed class GamepadEvent {
  const GamepadEvent({
    required this.gamepadId,
    required this.timestamp,
  });

  /// Identifier of the gamepad that produced this event.
  final int gamepadId;

  /// Timestamp of the event in milliseconds since epoch.
  final int timestamp;

  /// Deserializes a [GamepadEvent] from a fixed-position list.
  ///
  /// Wire format — element 0 is the type tag (int):
  ///   0 = connection, 1 = button, 2 = axis.
  factory GamepadEvent.fromList(List list) {
    final type = list[0] as int;
    return switch (type) {
      0 => GamepadConnectionEvent.fromList(list),
      1 => GamepadButtonEvent.fromList(list),
      2 => GamepadAxisEvent.fromList(list),
      _ => throw ArgumentError('Unknown gamepad event type: $type'),
    };
  }
}

/// Fired when a gamepad is connected or disconnected.
class GamepadConnectionEvent extends GamepadEvent {
  const GamepadConnectionEvent({
    required super.gamepadId,
    required super.timestamp,
    required this.connected,
    required this.info,
  });

  /// Whether the gamepad was connected (`true`) or disconnected (`false`).
  final bool connected;

  /// Information about the gamepad.
  final GamepadInfo info;

  /// Wire format: [0, gamepadId(int), timestamp, connected, name, vendorId, productId]
  factory GamepadConnectionEvent.fromList(List list) {
    final id = list[1] as int;
    return GamepadConnectionEvent(
      gamepadId: id,
      timestamp: list[2] as int,
      connected: list[3] as bool,
      info: GamepadInfo(
        id: id,
        name: (list[4] as String?) ?? 'Unknown',
        vendorId: list[5] as int?,
        productId: list[6] as int?,
      ),
    );
  }
}

/// Fired when a gamepad button is pressed or released.
class GamepadButtonEvent extends GamepadEvent {
  const GamepadButtonEvent({
    required super.gamepadId,
    required super.timestamp,
    required this.button,
    required this.pressed,
    required this.value,
  });

  /// The button that changed state.
  final GamepadButton button;

  /// Whether the button is currently pressed.
  final bool pressed;

  /// Analog value of the button press (0.0 = released, 1.0 = fully pressed).
  /// For digital buttons, this will be 0.0 or 1.0.
  final double value;

  /// Wire format: [1, gamepadId(int), timestamp, buttonIndex, pressed, value]
  factory GamepadButtonEvent.fromList(List list) {
    final buttonIndex = list[3] as int;
    final button = GamepadButton.fromIndex(buttonIndex);
    if (button == null) {
      throw ArgumentError('Unknown button index: $buttonIndex');
    }
    return GamepadButtonEvent(
      gamepadId: list[1] as int,
      timestamp: list[2] as int,
      button: button,
      pressed: list[4] as bool,
      value: (list[5] as num).toDouble(),
    );
  }
}

/// Fired when a gamepad axis value changes.
class GamepadAxisEvent extends GamepadEvent {
  const GamepadAxisEvent({
    required super.gamepadId,
    required super.timestamp,
    required this.axis,
    required this.value,
  });

  /// The axis that changed value.
  final GamepadAxis axis;

  /// Current axis value (-1.0 to 1.0).
  final double value;

  /// Wire format: [2, gamepadId(int), timestamp, axisIndex, value]
  factory GamepadAxisEvent.fromList(List list) {
    final axisIndex = list[3] as int;
    final axis = GamepadAxis.fromIndex(axisIndex);
    if (axis == null) {
      throw ArgumentError('Unknown axis index: $axisIndex');
    }
    return GamepadAxisEvent(
      gamepadId: list[1] as int,
      timestamp: list[2] as int,
      axis: axis,
      value: (list[4] as num).toDouble(),
    );
  }
}
