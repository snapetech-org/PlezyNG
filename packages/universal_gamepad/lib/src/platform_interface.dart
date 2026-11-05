import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'method_channel.dart';
import 'types/gamepad_event.dart';
import 'types/gamepad_info.dart';

/// The interface that implementations of gamepad must implement.
abstract class GamepadPlatform extends PlatformInterface {
  GamepadPlatform() : super(token: _token);

  static final Object _token = Object();

  static GamepadPlatform _instance = MethodChannelGamepad();

  static GamepadPlatform get instance => _instance;

  static set instance(GamepadPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Stream of all gamepad events from the native platform.
  Stream<GamepadEvent> get events {
    throw UnimplementedError('events has not been implemented.');
  }

  /// Returns a list of currently connected gamepads.
  Future<List<GamepadInfo>> listGamepads() {
    throw UnimplementedError('listGamepads() has not been implemented.');
  }

  /// Releases native resources.
  Future<void> dispose() {
    throw UnimplementedError('dispose() has not been implemented.');
  }

  /// Pauses native gamepad polling, releasing device handles.
  /// No-op on platforms that don't hold exclusive device access.
  Future<void> pause() async {}

  /// Resumes native gamepad polling after a [pause].
  Future<void> resume() async {}
}
