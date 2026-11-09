## 0.3.0

- Added `OsMediaControls.setBackgroundMode(bool)`: on Android, playback now
  drives a `mediaPlayback` foreground service with a MediaStyle notification
  (previous / play-pause / next), so audio keeps running while the app is
  backgrounded. Playing = foreground with an ongoing notification; paused =
  service stays alive with a dismissible, updatable notification; stop /
  `clear()` / disable = service stopped and notification removed. No-op on
  other platforms.
- Android now honors `MediaMetadata.artworkUrl`: artwork is downloaded and
  downsampled off the main thread (with a small cache) and applied to the
  media session and notification. Raw `artwork` bytes still take precedence.
- The Android media session token is exposed to the new service through a
  process-local holder; the service stops itself (and removes its
  notification) on engine detach and on task removal.
- iOS and macOS now support Swift Package Manager while retaining CocoaPods compatibility.

## 0.2.4

- Fixed tvOS Play/Pause remote handling after playback is paused.
- Fixed tvOS Siri Remote Play/Pause button delivery by listening for the native Play/Pause press.
- Updated iOS/tvOS Now Playing playback state when playback changes.
- Re-register command handlers when queue info is set after clearing controls.

## 0.2.1

- Added cross-platform OS media controls for metadata, playback state, queue info, skip intervals, and control events.
- Added native implementations for Android, iOS, macOS, Windows, and Linux.
- Added an example media-player app demonstrating metadata updates and event handling.
