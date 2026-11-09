/// Available media control buttons/commands
enum MediaControl {
  /// Play button
  play,

  /// Pause button
  pause,

  /// Stop button (may not be available on all platforms)
  stop,

  /// Next track/skip forward button
  next,

  /// Previous track/skip backward button
  previous,

  /// Seek to position (enables seekbar)
  seek,

  /// Skip forward by interval (iOS/macOS)
  skipForward,

  /// Skip backward by interval (iOS/macOS)
  skipBackward,

  /// Change playback speed
  changeSpeed,
}
