import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';

class WebosSystemNavigationService {
  static const BasicMessageChannel<Object?> _channel = BasicMessageChannel<Object?>(
    'com.plezy/webos_system_navigation',
    StandardMessageCodec(),
  );

  @visibleForTesting
  static bool? debugPlatformSupported;

  static bool? _latestDesiredValue;
  static bool? _lastAcknowledgedValue;
  static Future<void>? _inFlightUpdate;
  static bool _trailingUpdateRequested = false;

  static Future<void> setBackPassthroughEnabled(bool enabled) {
    if (!(debugPlatformSupported ?? PlatformDetector.isWebOSBuild())) return Future<void>.value();

    _latestDesiredValue = enabled;
    final activeUpdate = _inFlightUpdate;
    if (activeUpdate != null) {
      _trailingUpdateRequested = true;
      return activeUpdate;
    }
    if (_lastAcknowledgedValue == enabled) return Future<void>.value();

    final update = _runUpdateLoopAndClear();
    _inFlightUpdate = update;
    return update;
  }

  static Future<void> _runUpdateLoopAndClear() async {
    try {
      await _runUpdateLoop();
    } finally {
      _inFlightUpdate = null;
    }
  }

  static Future<void> _runUpdateLoop() async {
    do {
      _trailingUpdateRequested = false;
      final desired = _latestDesiredValue;
      if (desired == null || desired == _lastAcknowledgedValue) continue;

      try {
        final reply = await _channel.send({'backPassthroughEnabled': desired});
        if (reply == true) {
          _lastAcknowledgedValue = desired;
        }
      } on PlatformException catch (error, stackTrace) {
        appLogger.w('Failed to update webOS Back passthrough state', error: error, stackTrace: stackTrace);
      }
    } while (_trailingUpdateRequested);
  }

  @visibleForTesting
  static void resetForTesting() {
    assert(_inFlightUpdate == null, 'Await the active webOS navigation update before resetting');
    debugPlatformSupported = null;
    _latestDesiredValue = null;
    _lastAcknowledgedValue = null;
    _trailingUpdateRequested = false;
    _inFlightUpdate = null;
  }
}
