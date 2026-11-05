import 'platform_interface.dart';
import 'types/gamepad_event.dart';
import 'types/gamepad_info.dart';

/// Unified gamepad input API for all Flutter platforms.
///
/// Access via [Gamepad.instance]. Provides streams of gamepad events
/// (connections, buttons, axes) and a method to list connected gamepads.
class Gamepad {
  Gamepad._();

  static final instance = Gamepad._();

  /// Stream of all gamepad events (connections, buttons, axes).
  Stream<GamepadEvent> get events => GamepadPlatform.instance.events;

  /// Stream of connection/disconnection events only.
  Stream<GamepadConnectionEvent> get connectionEvents =>
      events.where((e) => e is GamepadConnectionEvent).cast();

  /// Stream of button press/release events only.
  Stream<GamepadButtonEvent> get buttonEvents =>
      events.where((e) => e is GamepadButtonEvent).cast();

  /// Stream of axis value change events only.
  Stream<GamepadAxisEvent> get axisEvents =>
      events.where((e) => e is GamepadAxisEvent).cast();

  /// Returns a list of currently connected gamepads.
  Future<List<GamepadInfo>> listGamepads() =>
      GamepadPlatform.instance.listGamepads();

  /// Releases native resources. After calling this, the instance
  /// should not be used until a new stream is requested.
  Future<void> dispose() => GamepadPlatform.instance.dispose();

  /// Pauses native gamepad input, releasing device handles / input listeners
  /// so other apps can use gamepads. Only has effect on Android and Windows;
  /// a no-op elsewhere.
  Future<void> pause() => GamepadPlatform.instance.pause();

  /// Resumes native gamepad input after a [pause]. Connected gamepads
  /// will be re-detected and emit connection events.
  Future<void> resume() => GamepadPlatform.instance.resume();
}
