import 'dart:async';

/// Controls return to the existing media route, including its room, seek and
/// progress policies. A window never constructs another Dart playback owner.
enum NativeVideoWindowAction { togglePlayback, seekBackward, seekForward }

typedef NativeVideoWindowIntent = FutureOr<void> Function(NativeVideoWindowAction action);

NativeVideoWindowAction? nativeVideoWindowAction(Object? value) => switch (value) {
  'togglePlayback' => NativeVideoWindowAction.togglePlayback,
  'seekBackward' => NativeVideoWindowAction.seekBackward,
  'seekForward' => NativeVideoWindowAction.seekForward,
  _ => null,
};
