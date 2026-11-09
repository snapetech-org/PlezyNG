import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'os_media_controls_platform_interface.dart';
import 'src/media_control.dart';
import 'src/media_control_event.dart';
import 'src/media_metadata.dart';
import 'src/playback_state.dart';

/// An implementation of [OsMediaControlsPlatform] that uses method channels.
class MethodChannelOsMediaControls extends OsMediaControlsPlatform {
  MethodChannelOsMediaControls({
    this.methodChannel = const MethodChannel(
      'com.edde746.os_media_controls/methods',
    ),
    this.eventChannel = const EventChannel(
      'com.edde746.os_media_controls/events',
    ),
  });

  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final MethodChannel methodChannel;

  /// The event channel used to receive native control events.
  @visibleForTesting
  final EventChannel eventChannel;

  Stream<MediaControlEvent>? _eventStream;

  @override
  Stream<MediaControlEvent> get controlEvents {
    _eventStream ??= eventChannel.receiveBroadcastStream().map((dynamic event) {
      if (event is Map) {
        return MediaControlEvent.fromMap(event);
      }
      throw ArgumentError('Invalid event format');
    });
    return _eventStream!;
  }

  @override
  Future<void> setMetadata(MediaMetadata metadata) async {
    try {
      await methodChannel.invokeMethod('setMetadata', metadata.toMap());
    } on PlatformException catch (e) {
      throw Exception('Failed to set metadata: ${e.message}');
    }
  }

  @override
  Future<void> setPlaybackState(MediaPlaybackState state) async {
    try {
      await methodChannel.invokeMethod('setPlaybackState', state.toMap());
    } on PlatformException catch (e) {
      throw Exception('Failed to set playback state: ${e.message}');
    }
  }

  @override
  Future<void> enableControls(List<MediaControl> controls) async {
    try {
      await methodChannel.invokeMethod(
        'enableControls',
        controls.map((c) => c.name).toList(),
      );
    } on PlatformException catch (e) {
      throw Exception('Failed to enable controls: ${e.message}');
    }
  }

  @override
  Future<void> disableControls(List<MediaControl> controls) async {
    try {
      await methodChannel.invokeMethod(
        'disableControls',
        controls.map((c) => c.name).toList(),
      );
    } on PlatformException catch (e) {
      throw Exception('Failed to disable controls: ${e.message}');
    }
  }

  @override
  Future<void> setSkipIntervals({Duration? forward, Duration? backward}) async {
    try {
      await methodChannel.invokeMethod('setSkipIntervals', {
        if (forward != null) 'forward': forward.inSeconds,
        if (backward != null) 'backward': backward.inSeconds,
      });
    } on PlatformException catch (e) {
      throw Exception('Failed to set skip intervals: ${e.message}');
    }
  }

  @override
  Future<void> setQueueInfo({
    required int currentIndex,
    required int queueLength,
  }) async {
    try {
      await methodChannel.invokeMethod('setQueueInfo', {
        'currentIndex': currentIndex,
        'queueLength': queueLength,
      });
    } on PlatformException catch (e) {
      throw Exception('Failed to set queue info: ${e.message}');
    }
  }

  @override
  Future<void> setBackgroundMode(bool enabled) async {
    // Only the Android implementation backs media controls with a foreground
    // service; the other platforms keep controls alive without one.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await methodChannel.invokeMethod('setBackgroundMode', {
        'enabled': enabled,
      });
    } on PlatformException catch (e) {
      throw Exception('Failed to set background mode: ${e.message}');
    }
  }

  @override
  Future<void> clear() async {
    try {
      await methodChannel.invokeMethod('clear');
    } on PlatformException catch (e) {
      throw Exception('Failed to clear media controls: ${e.message}');
    }
  }
}
