/// Base class for all media control events received from the OS
abstract class MediaControlEvent {
  const MediaControlEvent();

  /// Creates a [MediaControlEvent] from a platform channel map
  factory MediaControlEvent.fromMap(Map<dynamic, dynamic> map) {
    final type = map['type'] as String;
    switch (type) {
      case 'play':
        return const PlayEvent();
      case 'pause':
        return const PauseEvent();
      case 'stop':
        return const StopEvent();
      case 'next':
        return const NextTrackEvent();
      case 'previous':
        return const PreviousTrackEvent();
      case 'seek':
        final position = (map['position'] as num).toDouble();
        return SeekEvent(Duration(milliseconds: (position * 1000).round()));
      case 'skipForward':
        final interval = (map['interval'] as num?)?.toDouble();
        return SkipForwardEvent(
          interval != null
              ? Duration(milliseconds: (interval * 1000).round())
              : null,
        );
      case 'skipBackward':
        final interval = (map['interval'] as num?)?.toDouble();
        return SkipBackwardEvent(
          interval != null
              ? Duration(milliseconds: (interval * 1000).round())
              : null,
        );
      case 'setSpeed':
        final speed = (map['speed'] as num).toDouble();
        return SetSpeedEvent(speed);
      case 'togglePlayPause':
        return const TogglePlayPauseEvent();
      case 'audioInterruptionBegan':
        return const AudioInterruptionBeganEvent();
      case 'audioInterruptionEnded':
        return AudioInterruptionEndedEvent(
          shouldResume: map['shouldResume'] == true,
        );
      case 'audioRouteOldDeviceUnavailable':
        return const AudioRouteOldDeviceUnavailableEvent();
      case 'audioRouteNewDeviceAvailable':
        return const AudioRouteNewDeviceAvailableEvent();
      default:
        throw ArgumentError('Unknown event type: $type');
    }
  }
}

/// Event triggered when the play button is pressed
class PlayEvent extends MediaControlEvent {
  const PlayEvent();

  @override
  String toString() => 'PlayEvent()';
}

/// Event triggered when the pause button is pressed
class PauseEvent extends MediaControlEvent {
  const PauseEvent();

  @override
  String toString() => 'PauseEvent()';
}

/// Event triggered when the stop button is pressed
class StopEvent extends MediaControlEvent {
  const StopEvent();

  @override
  String toString() => 'StopEvent()';
}

/// Event triggered when the toggle play/pause button is pressed (iOS/macOS)
class TogglePlayPauseEvent extends MediaControlEvent {
  const TogglePlayPauseEvent();

  @override
  String toString() => 'TogglePlayPauseEvent()';
}

/// Event triggered when the iOS audio session is interrupted.
class AudioInterruptionBeganEvent extends MediaControlEvent {
  const AudioInterruptionBeganEvent();

  @override
  String toString() => 'AudioInterruptionBeganEvent()';
}

/// Event triggered when an iOS audio session interruption ends.
class AudioInterruptionEndedEvent extends MediaControlEvent {
  /// Whether the system says playback should resume automatically.
  final bool shouldResume;

  const AudioInterruptionEndedEvent({required this.shouldResume});

  @override
  String toString() =>
      'AudioInterruptionEndedEvent(shouldResume: $shouldResume)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AudioInterruptionEndedEvent &&
        other.shouldResume == shouldResume;
  }

  @override
  int get hashCode => shouldResume.hashCode;
}

/// Event triggered when a private audio route is disconnected on iOS.
class AudioRouteOldDeviceUnavailableEvent extends MediaControlEvent {
  const AudioRouteOldDeviceUnavailableEvent();

  @override
  String toString() => 'AudioRouteOldDeviceUnavailableEvent()';
}

/// Event triggered when a private audio route is connected on iOS.
class AudioRouteNewDeviceAvailableEvent extends MediaControlEvent {
  const AudioRouteNewDeviceAvailableEvent();

  @override
  String toString() => 'AudioRouteNewDeviceAvailableEvent()';
}

/// Event triggered when the next track button is pressed
class NextTrackEvent extends MediaControlEvent {
  const NextTrackEvent();

  @override
  String toString() => 'NextTrackEvent()';
}

/// Event triggered when the previous track button is pressed
class PreviousTrackEvent extends MediaControlEvent {
  const PreviousTrackEvent();

  @override
  String toString() => 'PreviousTrackEvent()';
}

/// Event triggered when the user seeks to a specific position
class SeekEvent extends MediaControlEvent {
  /// The position to seek to
  final Duration position;

  const SeekEvent(this.position);

  @override
  String toString() => 'SeekEvent(position: $position)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SeekEvent && other.position == position;
  }

  @override
  int get hashCode => position.hashCode;
}

/// Event triggered when the skip forward button is pressed (iOS/macOS)
class SkipForwardEvent extends MediaControlEvent {
  /// The interval to skip forward, if specified
  final Duration? interval;

  const SkipForwardEvent(this.interval);

  @override
  String toString() => 'SkipForwardEvent(interval: $interval)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SkipForwardEvent && other.interval == interval;
  }

  @override
  int get hashCode => interval.hashCode;
}

/// Event triggered when the skip backward button is pressed (iOS/macOS)
class SkipBackwardEvent extends MediaControlEvent {
  /// The interval to skip backward, if specified
  final Duration? interval;

  const SkipBackwardEvent(this.interval);

  @override
  String toString() => 'SkipBackwardEvent(interval: $interval)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SkipBackwardEvent && other.interval == interval;
  }

  @override
  int get hashCode => interval.hashCode;
}

/// Event triggered when playback speed change is requested
class SetSpeedEvent extends MediaControlEvent {
  /// The requested playback speed (1.0 = normal speed)
  final double speed;

  const SetSpeedEvent(this.speed);

  @override
  String toString() => 'SetSpeedEvent(speed: $speed)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SetSpeedEvent && other.speed == speed;
  }

  @override
  int get hashCode => speed.hashCode;
}
