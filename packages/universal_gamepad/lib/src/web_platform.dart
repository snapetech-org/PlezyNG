import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'platform_interface.dart';
import 'types/gamepad_axis.dart';
import 'types/gamepad_button.dart';
import 'types/gamepad_event.dart';
import 'types/gamepad_info.dart';

/// Web implementation of [GamepadPlatform] using the W3C Gamepad API.
class WebGamepad extends GamepadPlatform {
  WebGamepad._();

  static void registerWith(Registrar registrar) {
    GamepadPlatform.instance = WebGamepad._();
  }

  StreamController<GamepadEvent>? _controller;
  int? _animationFrameId;
  final Map<int, _GamepadState> _previousStates = {};

  web.EventHandler? _connectHandler;
  web.EventHandler? _disconnectHandler;

  @override
  Stream<GamepadEvent> get events {
    _controller ??= StreamController<GamepadEvent>.broadcast(
      onListen: _startPolling,
      onCancel: _stopPolling,
    );
    return _controller!.stream;
  }

  @override
  Future<List<GamepadInfo>> listGamepads() async {
    final gamepads = web.window.navigator.getGamepads().toDart;
    final result = <GamepadInfo>[];
    for (final gp in gamepads) {
      if (gp == null) continue;
      final gamepad = gp;
      result.add(GamepadInfo(
        id: gamepad.index,
        name: gamepad.id,
      ));
    }
    return result;
  }

  @override
  Future<void> dispose() async {
    _stopPolling();
    await _controller?.close();
    _controller = null;
  }

  void _startPolling() {
    _connectHandler = (web.Event event) {
      final ge = event as web.GamepadEvent;
      final gamepad = ge.gamepad;
      final now = DateTime.now().millisecondsSinceEpoch;
      _controller?.add(GamepadConnectionEvent(
        gamepadId: gamepad.index,
        timestamp: now,
        connected: true,
        info: GamepadInfo(
          id: gamepad.index,
          name: gamepad.id,
        ),
      ));
    }.toJS;

    _disconnectHandler = (web.Event event) {
      final ge = event as web.GamepadEvent;
      final gamepad = ge.gamepad;
      final now = DateTime.now().millisecondsSinceEpoch;
      _previousStates.remove(gamepad.index);
      _controller?.add(GamepadConnectionEvent(
        gamepadId: gamepad.index,
        timestamp: now,
        connected: false,
        info: GamepadInfo(
          id: gamepad.index,
          name: gamepad.id,
        ),
      ));
    }.toJS;

    web.window.addEventListener('gamepadconnected', _connectHandler);
    web.window.addEventListener('gamepaddisconnected', _disconnectHandler);

    _pollFrame(0.0.toJS);
  }

  void _stopPolling() {
    if (_animationFrameId != null) {
      web.window.cancelAnimationFrame(_animationFrameId!);
      _animationFrameId = null;
    }
    if (_connectHandler != null) {
      web.window.removeEventListener('gamepadconnected', _connectHandler);
      _connectHandler = null;
    }
    if (_disconnectHandler != null) {
      web.window.removeEventListener('gamepaddisconnected', _disconnectHandler);
      _disconnectHandler = null;
    }
    _previousStates.clear();
  }

  void _pollFrame(JSNumber timestamp) {
    _diffGamepadState();
    _animationFrameId = web.window.requestAnimationFrame(_pollFrame.toJS);
  }

  void _diffGamepadState() {
    final gamepads = web.window.navigator.getGamepads().toDart;
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final gp in gamepads) {
      if (gp == null) continue;
      final gamepad = gp;
      final id = gamepad.index;

      final buttons = gamepad.buttons.toDart;
      final axes = gamepad.axes.toDart;

      final prev = _previousStates[id];

      // Check buttons
      for (var i = 0; i < buttons.length && i < 17; i++) {
        final button = buttons[i];
        final pressed = button.pressed;
        final value = button.value;
        final prevPressed = prev?.buttonPressed[i] ?? false;
        final prevValue = prev?.buttonValues[i] ?? 0.0;

        if (pressed != prevPressed || (value - prevValue).abs() > 0.01) {
          final b = GamepadButton.fromIndex(i);
          if (b != null) {
            _controller?.add(GamepadButtonEvent(
              gamepadId: id,
              timestamp: now,
              button: b,
              pressed: pressed,
              value: value,
            ));
          }
        }
      }

      // Check axes
      for (var i = 0; i < axes.length && i < 4; i++) {
        final value = axes[i].toDartDouble;
        final prevValue = prev?.axisValues[i] ?? 0.0;

        if ((value - prevValue).abs() > 0.01) {
          final a = GamepadAxis.fromIndex(i);
          if (a != null) {
            _controller?.add(GamepadAxisEvent(
              gamepadId: id,
              timestamp: now,
              axis: a,
              value: value,
            ));
          }
        }
      }

      // Update stored state
      _previousStates[id] = _GamepadState(
        buttonPressed: [
          for (var i = 0; i < buttons.length && i < 17; i++)
            buttons[i].pressed,
        ],
        buttonValues: [
          for (var i = 0; i < buttons.length && i < 17; i++)
            buttons[i].value,
        ],
        axisValues: [
          for (var i = 0; i < axes.length && i < 4; i++)
            axes[i].toDartDouble,
        ],
      );
    }
  }
}

class _GamepadState {
  _GamepadState({
    required this.buttonPressed,
    required this.buttonValues,
    required this.axisValues,
  });

  final List<bool> buttonPressed;
  final List<double> buttonValues;
  final List<double> axisValues;
}
