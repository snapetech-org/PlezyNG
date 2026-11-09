import 'dart:async';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'os_media_controls_method_channel.dart';
import 'src/media_control.dart';
import 'src/media_control_event.dart';
import 'src/media_metadata.dart';
import 'src/playback_state.dart';

abstract class OsMediaControlsPlatform extends PlatformInterface {
  /// Constructs a OsMediaControlsPlatform.
  OsMediaControlsPlatform() : super(token: _token);

  static final Object _token = Object();

  static OsMediaControlsPlatform _instance = MethodChannelOsMediaControls();

  /// The default instance of [OsMediaControlsPlatform] to use.
  ///
  /// Defaults to [MethodChannelOsMediaControls].
  static OsMediaControlsPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [OsMediaControlsPlatform] when
  /// they register themselves.
  static set instance(OsMediaControlsPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Stream of control events from the operating system.
  Stream<MediaControlEvent> get controlEvents {
    throw UnimplementedError('controlEvents has not been implemented.');
  }

  /// Updates the metadata displayed in system media controls.
  Future<void> setMetadata(MediaMetadata metadata) {
    throw UnimplementedError('setMetadata() has not been implemented.');
  }

  /// Updates the current playback state.
  Future<void> setPlaybackState(MediaPlaybackState state) {
    throw UnimplementedError('setPlaybackState() has not been implemented.');
  }

  /// Enables specific media controls.
  Future<void> enableControls(List<MediaControl> controls) {
    throw UnimplementedError('enableControls() has not been implemented.');
  }

  /// Disables specific media controls.
  Future<void> disableControls(List<MediaControl> controls) {
    throw UnimplementedError('disableControls() has not been implemented.');
  }

  /// Sets custom skip intervals for skip forward/backward buttons.
  Future<void> setSkipIntervals({Duration? forward, Duration? backward}) {
    throw UnimplementedError('setSkipIntervals() has not been implemented.');
  }

  /// Sets queue information for the current playback session.
  Future<void> setQueueInfo({
    required int currentIndex,
    required int queueLength,
  }) {
    throw UnimplementedError('setQueueInfo() has not been implemented.');
  }

  /// Enables or disables background playback support.
  ///
  /// Android only; a no-op elsewhere.
  Future<void> setBackgroundMode(bool enabled) {
    throw UnimplementedError('setBackgroundMode() has not been implemented.');
  }

  /// Clears all media information from system controls.
  Future<void> clear() {
    throw UnimplementedError('clear() has not been implemented.');
  }
}
