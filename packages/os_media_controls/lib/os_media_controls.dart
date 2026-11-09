import 'dart:async';

import 'os_media_controls_platform_interface.dart';
import 'src/media_metadata.dart';
import 'src/playback_state.dart';
import 'src/media_control.dart';
import 'src/media_control_event.dart';

export 'src/media_metadata.dart';
export 'src/playback_state.dart';
export 'src/media_control.dart';
export 'src/media_control_event.dart';

/// Main class for controlling OS-level media controls.
///
/// This class provides functionality to integrate with system media controls
/// across iOS, macOS, Android, and Windows platforms. It allows you to:
///
/// - Display media metadata (title, artist, album, artwork) in system UI
/// - Update playback state and position
/// - Receive control events (play, pause, next, previous, seek, etc.)
/// - Enable/disable specific controls
/// - Configure platform-specific features (skip intervals, queue info)
///
/// ## Usage Example:
///
/// ```dart
/// // Set up metadata
/// await OsMediaControls.setMetadata(MediaMetadata(
///   title: 'Song Title',
///   artist: 'Artist Name',
///   album: 'Album Name',
///   duration: Duration(minutes: 3, seconds: 45),
/// ));
///
/// // Update playback state
/// await OsMediaControls.setPlaybackState(MediaPlaybackState(
///   state: PlaybackState.playing,
///   position: Duration(seconds: 10),
///   speed: 1.0,
/// ));
///
/// // Listen to control events
/// OsMediaControls.controlEvents.listen((event) {
///   if (event is PlayEvent) {
///     // Handle play
///   } else if (event is PauseEvent) {
///     // Handle pause
///   }
/// });
/// ```
class OsMediaControls {
  /// Stream of control events from the operating system.
  ///
  /// Subscribe to this stream to receive events when users interact with
  /// media controls (play button, pause button, seek bar, etc.).
  ///
  /// The stream emits various event types:
  /// - [PlayEvent]: Play button pressed
  /// - [PauseEvent]: Pause button pressed
  /// - [StopEvent]: Stop button pressed
  /// - [TogglePlayPauseEvent]: Toggle play/pause button pressed (iOS/macOS)
  /// - [AudioInterruptionBeganEvent]: Audio session interruption started (iOS)
  /// - [AudioInterruptionEndedEvent]: Audio session interruption ended (iOS)
  /// - [AudioRouteOldDeviceUnavailableEvent]: Private audio route disconnected (iOS)
  /// - [AudioRouteNewDeviceAvailableEvent]: Private audio route connected (iOS)
  /// - [NextTrackEvent]: Next track button pressed
  /// - [PreviousTrackEvent]: Previous track button pressed
  /// - [SeekEvent]: User seeked to a position
  /// - [SkipForwardEvent]: Skip forward button pressed (iOS/macOS)
  /// - [SkipBackwardEvent]: Skip backward button pressed (iOS/macOS)
  /// - [SetSpeedEvent]: Playback speed change requested
  static Stream<MediaControlEvent> get controlEvents =>
      OsMediaControlsPlatform.instance.controlEvents;

  /// Updates the metadata displayed in system media controls.
  ///
  /// This information appears in various system UI elements:
  /// - iOS/macOS: Lock screen, Control Center, CarPlay
  /// - Android: Notification, Quick Settings, Android Auto
  /// - Windows: Media overlay, Game Bar
  ///
  /// At minimum, you should provide a [title]. Other fields are optional
  /// but recommended for a better user experience.
  ///
  /// Example:
  /// ```dart
  /// await OsMediaControls.setMetadata(MediaMetadata(
  ///   title: 'Bohemian Rhapsody',
  ///   artist: 'Queen',
  ///   album: 'A Night at the Opera',
  ///   duration: Duration(minutes: 5, seconds: 55),
  ///   artwork: await loadArtworkBytes(),
  /// ));
  /// ```
  static Future<void> setMetadata(MediaMetadata metadata) async {
    await OsMediaControlsPlatform.instance.setMetadata(metadata);
  }

  /// Updates the current playback state.
  ///
  /// This should be called whenever the playback state changes (playing,
  /// paused, stopped) or when the position updates.
  ///
  /// The [speed] parameter affects how the system calculates the current
  /// position over time:
  /// - 0.0: Paused (position doesn't advance)
  /// - 1.0: Normal playback speed
  /// - 2.0: Double speed
  ///
  /// For best results, update the position every 1-5 seconds during playback.
  ///
  /// Example:
  /// ```dart
  /// // When starting playback
  /// await OsMediaControls.setPlaybackState(MediaPlaybackState(
  ///   state: PlaybackState.playing,
  ///   position: currentPosition,
  ///   speed: 1.0,
  /// ));
  ///
  /// // When pausing
  /// await OsMediaControls.setPlaybackState(MediaPlaybackState(
  ///   state: PlaybackState.paused,
  ///   position: currentPosition,
  ///   speed: 0.0,
  /// ));
  /// ```
  static Future<void> setPlaybackState(MediaPlaybackState state) async {
    await OsMediaControlsPlatform.instance.setPlaybackState(state);
  }

  /// Enables specific media controls.
  ///
  /// By default, most controls are enabled. Use this method to explicitly
  /// enable controls that may have been disabled, or to ensure specific
  /// controls are available.
  ///
  /// Note: Not all platforms support all controls. For example:
  /// - [MediaControl.skipForward] and [MediaControl.skipBackward] are
  ///   primarily supported on iOS/macOS
  /// - [MediaControl.stop] may not be available on all platforms
  ///
  /// Example:
  /// ```dart
  /// await OsMediaControls.enableControls([
  ///   MediaControl.play,
  ///   MediaControl.pause,
  ///   MediaControl.next,
  ///   MediaControl.previous,
  ///   MediaControl.seek,
  /// ]);
  /// ```
  static Future<void> enableControls(List<MediaControl> controls) async {
    await OsMediaControlsPlatform.instance.enableControls(controls);
  }

  /// Disables specific media controls.
  ///
  /// Use this to hide controls that are not applicable to your current
  /// playback context. For example, disable [MediaControl.next] and
  /// [MediaControl.previous] when playing a single item.
  ///
  /// Example:
  /// ```dart
  /// // Disable next/previous for single-item playback
  /// await OsMediaControls.disableControls([
  ///   MediaControl.next,
  ///   MediaControl.previous,
  /// ]);
  /// ```
  static Future<void> disableControls(List<MediaControl> controls) async {
    await OsMediaControlsPlatform.instance.disableControls(controls);
  }

  /// Sets custom skip intervals for skip forward/backward buttons.
  ///
  /// This is primarily supported on iOS and macOS. When set, the skip
  /// forward and skip backward buttons will skip by the specified intervals
  /// instead of going to the next/previous track.
  ///
  /// Common intervals are 15 or 30 seconds for podcasts.
  ///
  /// On other platforms, this method may have no effect.
  ///
  /// Example:
  /// ```dart
  /// // Set 15-second skip intervals for podcast playback
  /// await OsMediaControls.setSkipIntervals(
  ///   forward: Duration(seconds: 15),
  ///   backward: Duration(seconds: 15),
  /// );
  /// ```
  static Future<void> setSkipIntervals({
    Duration? forward,
    Duration? backward,
  }) async {
    await OsMediaControlsPlatform.instance.setSkipIntervals(
      forward: forward,
      backward: backward,
    );
  }

  /// Sets queue information for the current playback session.
  ///
  /// This is primarily supported on iOS and macOS, where it displays
  /// the current track index and total track count in the Now Playing UI.
  ///
  /// Example:
  /// ```dart
  /// // Show "Track 3 of 12"
  /// await OsMediaControls.setQueueInfo(
  ///   currentIndex: 2,  // 0-based index
  ///   queueLength: 12,
  /// );
  /// ```
  static Future<void> setQueueInfo({
    required int currentIndex,
    required int queueLength,
  }) async {
    await OsMediaControlsPlatform.instance.setQueueInfo(
      currentIndex: currentIndex,
      queueLength: queueLength,
    );
  }

  /// Enables or disables background playback support (Android only).
  ///
  /// While enabled, the Android implementation runs a `mediaPlayback`
  /// foreground service whenever playback is active, which keeps audio
  /// running when the app is backgrounded and renders the media session as
  /// a MediaStyle notification (with previous / play-pause / next actions
  /// for the controls that are enabled):
  ///
  /// - playing: service runs in the foreground (ongoing notification)
  /// - paused: service stays alive but leaves the foreground; the
  ///   notification remains, updatable and dismissible
  /// - stopped / [clear] / disabled: service stops and the notification is
  ///   removed
  ///
  /// Call with `true` when an audio session starts and `false` when it
  /// ends. Sessions that never enable it (e.g. video playback, which the OS
  /// keeps alive on its own) behave exactly as before. No-op on all other
  /// platforms.
  ///
  /// Note: on Android 13+ the notification is only visible if the app holds
  /// the `POST_NOTIFICATIONS` runtime permission; the service and playback
  /// work regardless.
  static Future<void> setBackgroundMode(bool enabled) async {
    await OsMediaControlsPlatform.instance.setBackgroundMode(enabled);
  }

  /// Clears all media information from system controls.
  ///
  /// Call this when stopping playback completely or when your app is
  /// no longer playing media.
  ///
  /// Example:
  /// ```dart
  /// await OsMediaControls.clear();
  /// ```
  static Future<void> clear() async {
    await OsMediaControlsPlatform.instance.clear();
  }
}
