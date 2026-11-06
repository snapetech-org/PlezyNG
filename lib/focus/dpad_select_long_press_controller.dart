import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult, VoidCallback;

import 'dpad_navigator.dart';

/// Tracks the timer and physical key state for a D-pad SELECT long press.
///
/// Focus loss, context-menu dispatch, and transferred/touch gesture suppression
/// stay with the caller because their behavior differs between widgets.
class DpadSelectLongPressController {
  static const defaultDuration = Duration(milliseconds: 500);

  Timer? _timer;
  PhysicalKeyboardKey? _pressedKey;

  KeyEventResult handleKeyEvent(
    KeyEvent event, {
    Duration duration = defaultDuration,
    required bool Function() isOwnerActive,
    required VoidCallback onShortPress,
    required VoidCallback onLongPress,
  }) {
    if (!event.logicalKey.isSelectKey) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      // Some platforms report another down instead of a repeat. Only the
      // transition from up to down may start (or restart) the timer.
      if (_pressedKey == null) {
        _pressedKey = event.physicalKey;
        _timer?.cancel();
        _timer = Timer(duration, () {
          if (!isOwnerActive() || _pressedKey == null) return;
          SelectKeyUpSuppressor.suppressSelectUntilKeyUp();
          onLongPress();
        });
      }
      return KeyEventResult.handled;
    }

    if (event is KeyRepeatEvent) return KeyEventResult.handled;

    if (event is KeyUpEvent) {
      // A second controller/keyboard SELECT must not release the first one's
      // hold or accidentally turn it into a short press.
      if (_pressedKey != event.physicalKey) return KeyEventResult.handled;
      final timerWasActive = _timer?.isActive ?? false;
      _timer?.cancel();
      _pressedKey = null;
      if (timerWasActive && isOwnerActive()) onShortPress();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void reset() {
    _timer?.cancel();
    _pressedKey = null;
  }

  void dispose() => reset();
}
