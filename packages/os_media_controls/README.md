# os_media_controls

Flutter plugin for OS-level media controls on iOS, tvOS, macOS, Android, Windows, and Linux. Displays rich media info in system UI and handles control events from lock screens, control centers, media keys, and MPRIS clients.

## Features

- Cross-platform: iOS, tvOS, macOS, Android, Windows, Linux
- Metadata: Title, artist, album, artwork, duration
- Controls: Play/pause/next/prev/seek/speed
- Integration: Lock screen, Control Center, MediaSession, SMTC, MPRIS, media keys
- Advanced: Custom skips (15/30s), queue display, speed control, position updates

## Platform Support

| Platform | Min Version | Notes |
|----------|-------------|-------|
| iOS     | 12.0+      | CarPlay, Siri, AirPlay |
| tvOS    | 13.0+      | Siri Remote, HDMI-CEC media keys |
| macOS   | 10.14+     | Control Center |
| Android | API 21+    | MediaSession, Auto/Wear |
| Windows | 10+        | SMTC (partial) |
| Linux   | GLib/GIO   | MPRIS over D-Bus |

## Installation

In `pubspec.yaml`:

```yaml
dependencies:
  os_media_controls: ^0.2.4
```

Run: `flutter pub get`

## Platform Setup

### iOS/tvOS

Add to `Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array><string>audio</string></array>
```

Update `AppDelegate.swift`:

```swift
import AVFoundation

// In didFinishLaunchingWithOptions:
do {
  let session = AVAudioSession.sharedInstance()
  try session.setCategory(.playback, mode: .default)
  try session.setActive(true)
} catch { print("Error: \(error)") }
application.beginReceivingRemoteControlEvents()
```

tvOS projects that use a custom Flutter tvOS engine may need to register the iOS plugin implementation manually because Flutter's stock tooling does not generate a tvOS plugin registrant.

### macOS

No extra setup.

### Android

No extra setup for foreground-only media controls.

For background audio playback, call `OsMediaControls.setBackgroundMode(true)` when an audio session starts (and `false` when it ends). The plugin then runs its own `mediaPlayback` foreground service while playback is active and renders the media session as a MediaStyle notification. The plugin manifest already merges the required `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_MEDIA_PLAYBACK` permissions and the service declaration into your app.

On Android 13+ the notification is only shown if your app holds the `POST_NOTIFICATIONS` runtime permission (playback and the service work without it). Optionally ship a drawable named `os_media_controls_notification_icon` to customize the status-bar icon; the launcher icon is used otherwise.

### Linux

Uses MPRIS over the session D-Bus. No extra setup is normally required on GNOME/KDE desktops.

### Windows

Uses SMTC; requires WinRT/C++ for full integration (basic structure provided).

## Usage

Import: `package:os_media_controls/os_media_controls.dart`

Listen to events:

```dart
OsMediaControls.controlEvents.listen((event) {
  if (event is PlayEvent) { play(); }
  // Handle others: Pause, Next, Prev, Seek, etc.
});
```

Set metadata:

```dart
await OsMediaControls.setMetadata(MediaMetadata(
  title: 'Title', artist: 'Artist', duration: Duration(minutes: 3),
  artwork: imageBytes,  // Uint8List
));
```

Set state:

```dart
await OsMediaControls.setPlaybackState(MediaPlaybackState(
  state: PlaybackState.playing, position: Duration(seconds: 30), speed: 1.0,
));
```

Update position periodically during playback.

Clear: `await OsMediaControls.clear();`

### Advanced

Skips (iOS/macOS):

```dart
await OsMediaControls.setSkipIntervals(forward: Duration(seconds: 15), backward: Duration(seconds: 15));
```

Queue (iOS/macOS): `await OsMediaControls.setQueueInfo(currentIndex: 2, queueLength: 12);`

Enable/disable: `await OsMediaControls.enableControls([MediaControl.play, MediaControl.pause]);`

## API Reference

### OsMediaControls Methods

- `setMetadata(MediaMetadata)`: Update metadata
- `setPlaybackState(MediaPlaybackState)`: Update state/position/speed
- `enableControls(List<MediaControl>)` / `disableControls(List<MediaControl>)`
- `setSkipIntervals({Duration? forward, backward})`
- `setQueueInfo({int currentIndex, queueLength})`
- `setBackgroundMode(bool)`: Android background playback (foreground service + notification); no-op elsewhere
- `clear()`
- `controlEvents`: Stream<MediaControlEvent> (PlayEvent, PauseEvent, SeekEvent, etc.)

### Models

- `MediaMetadata`: title (req), artist, album, duration, artwork (Uint8List), artworkUrl
- `MediaPlaybackState`: state (PlaybackState: none/stopped/paused/playing/buffering), position (req), speed
- `MediaControl`: play/pause/stop/next/prev/seek/skipForward/skipBackward/changeSpeed
- Events: PlayEvent, SeekEvent (position), SkipForwardEvent (interval), etc.
