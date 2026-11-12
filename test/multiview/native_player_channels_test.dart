import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/platform/player_android.dart';
import 'package:plezy/mpv/player/player_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MPV video slots have isolated method and event channels', () async {
    final primary = PlayerNative(listenToNativeEvents: false);
    final companion = PlayerNative(companionSession: true, listenToNativeEvents: false);
    final tertiary = PlayerNative(videoPlayerSlot: 2, listenToNativeEvents: false);
    final quaternary = PlayerNative(videoPlayerSlot: 3, listenToNativeEvents: false);
    addTearDown(primary.dispose);
    addTearDown(companion.dispose);
    addTearDown(tertiary.dispose);
    addTearDown(quaternary.dispose);

    expect(primary.methodChannel.name, 'com.plezy/mpv_player');
    expect(primary.eventChannel.name, 'com.plezy/mpv_player/events');
    expect(companion.methodChannel.name, 'com.plezy/mpv_player/workspace');
    expect(companion.eventChannel.name, 'com.plezy/mpv_player/workspace/events');
    expect(tertiary.methodChannel.name, 'com.plezy/mpv_player/workspace/2');
    expect(tertiary.eventChannel.name, 'com.plezy/mpv_player/workspace/2/events');
    expect(quaternary.methodChannel.name, 'com.plezy/mpv_player/workspace/3');
    expect(quaternary.eventChannel.name, 'com.plezy/mpv_player/workspace/3/events');
    expect(primary.methodChannel.name, isNot(companion.methodChannel.name));
    expect(primary.eventChannel.name, isNot(companion.eventChannel.name));
    expect({
      primary.methodChannel.name,
      companion.methodChannel.name,
      tertiary.methodChannel.name,
      quaternary.methodChannel.name,
    }, hasLength(4));
  });

  test('Android ExoPlayer video slots have isolated channels', () async {
    final primary = PlayerAndroid(listenToNativeEvents: false);
    final companion = PlayerAndroid(companionSession: true, listenToNativeEvents: false);
    final tertiary = PlayerAndroid(videoPlayerSlot: 2, listenToNativeEvents: false);
    final quaternary = PlayerAndroid(videoPlayerSlot: 3, listenToNativeEvents: false);
    addTearDown(primary.dispose);
    addTearDown(companion.dispose);
    addTearDown(tertiary.dispose);
    addTearDown(quaternary.dispose);

    expect(primary.methodChannel.name, 'com.plezy/exo_player');
    expect(primary.eventChannel.name, 'com.plezy/exo_player/events');
    expect(companion.methodChannel.name, 'com.plezy/exo_player/workspace');
    expect(companion.eventChannel.name, 'com.plezy/exo_player/workspace/events');
    expect(tertiary.methodChannel.name, 'com.plezy/exo_player/workspace/2');
    expect(tertiary.eventChannel.name, 'com.plezy/exo_player/workspace/2/events');
    expect(quaternary.methodChannel.name, 'com.plezy/exo_player/workspace/3');
    expect(quaternary.eventChannel.name, 'com.plezy/exo_player/workspace/3/events');
    expect(primary.methodChannel.name, isNot(companion.methodChannel.name));
    expect(primary.eventChannel.name, isNot(companion.eventChannel.name));

    final calls = <(String, Object?)>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(companion.methodChannel, (call) async {
      calls.add((call.method, call.arguments));
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(companion.methodChannel, null));

    await companion.setAudioFocusEnabled(false);

    expect(calls, hasLength(1));
    expect(calls.single.$1, 'setAudioFocusEnabled');
    expect(calls.single.$2, {'enabled': false});
  });
}
