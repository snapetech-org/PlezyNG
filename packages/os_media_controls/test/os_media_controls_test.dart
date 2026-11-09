import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:os_media_controls/os_media_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('com.edde746.os_media_controls/methods');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  });

  test('metadata serializes fractional duration and artwork URL', () {
    final metadata = MediaMetadata(
      title: 'Track',
      duration: const Duration(milliseconds: 1500),
      artwork: Uint8List.fromList(const [1, 2, 3]),
      artworkUrl: 'https://example.com/art.jpg',
    );

    expect(metadata.toMap(), {
      'title': 'Track',
      'duration': 1.5,
      'artwork': metadata.artwork,
      'artworkUrl': 'https://example.com/art.jpg',
    });
  });

  test('playback state serializes fractional position', () {
    const state = MediaPlaybackState(
      state: PlaybackState.playing,
      position: Duration(milliseconds: 2500),
      speed: 1.25,
    );

    expect(state.toMap(), {'state': 'playing', 'position': 2.5, 'speed': 1.25});
  });

  test('control events parse channel payloads', () {
    expect(MediaControlEvent.fromMap({'type': 'play'}), isA<PlayEvent>());
    expect(
      MediaControlEvent.fromMap({'type': 'seek', 'position': 12.345}),
      SeekEvent(const Duration(milliseconds: 12345)),
    );
    expect(
      MediaControlEvent.fromMap({'type': 'setSpeed', 'speed': 1.5}),
      const SetSpeedEvent(1.5),
    );
    expect(
      MediaControlEvent.fromMap({'type': 'audioInterruptionBegan'}),
      isA<AudioInterruptionBeganEvent>(),
    );
    expect(
      MediaControlEvent.fromMap({
        'type': 'audioInterruptionEnded',
        'shouldResume': true,
      }),
      const AudioInterruptionEndedEvent(shouldResume: true),
    );
    expect(
      MediaControlEvent.fromMap({'type': 'audioRouteOldDeviceUnavailable'}),
      isA<AudioRouteOldDeviceUnavailableEvent>(),
    );
    expect(
      MediaControlEvent.fromMap({'type': 'audioRouteNewDeviceAvailable'}),
      isA<AudioRouteNewDeviceAvailableEvent>(),
    );
  });

  test('static API forwards method calls to platform channel', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
          calls.add(call);
          return null;
        });

    await OsMediaControls.enableControls([
      MediaControl.play,
      MediaControl.pause,
    ]);
    await OsMediaControls.setPlaybackState(
      const MediaPlaybackState(
        state: PlaybackState.paused,
        position: Duration(milliseconds: 500),
        speed: 0,
      ),
    );

    expect(calls, hasLength(2));
    expect(calls[0].method, 'enableControls');
    expect(calls[0].arguments, ['play', 'pause']);
    expect(calls[1].method, 'setPlaybackState');
    expect(calls[1].arguments, {
      'state': 'paused',
      'position': 0.5,
      'speed': 0.0,
    });
  });

  test('setBackgroundMode forwards on Android and no-ops elsewhere', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
          calls.add(call);
          return null;
        });

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await OsMediaControls.setBackgroundMode(true);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'setBackgroundMode');
    expect(calls.single.arguments, {'enabled': true});

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await OsMediaControls.setBackgroundMode(true);
    expect(calls, hasLength(1), reason: 'non-Android platforms must no-op');
    debugDefaultTargetPlatformOverride = null;
  });
}
