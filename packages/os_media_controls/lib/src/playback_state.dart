/// The current state of media playback
enum PlaybackState {
  /// No media is loaded
  none,

  /// Playback has been stopped
  stopped,

  /// Playback is paused
  paused,

  /// Playback is active
  playing,

  /// Media is buffering/loading
  buffering,
}

/// Represents the current playback state including position and speed
class MediaPlaybackState {
  /// The current playback state
  final PlaybackState state;

  /// The current playback position
  final Duration position;

  /// The playback speed/rate
  ///
  /// - 0.0: Paused
  /// - 1.0: Normal playback speed
  /// - 2.0: 2x speed
  /// - 0.5: Half speed
  final double speed;

  const MediaPlaybackState({
    required this.state,
    required this.position,
    this.speed = 1.0,
  });

  /// Converts the playback state to a map for platform channel communication
  Map<String, dynamic> toMap() {
    return {
      'state': state.name,
      'position': position.inMilliseconds / Duration.millisecondsPerSecond,
      'speed': speed,
    };
  }

  @override
  String toString() {
    return 'MediaPlaybackState(state: $state, position: $position, speed: $speed)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is MediaPlaybackState &&
        other.state == state &&
        other.position == position &&
        other.speed == speed;
  }

  @override
  int get hashCode => Object.hash(state, position, speed);
}
