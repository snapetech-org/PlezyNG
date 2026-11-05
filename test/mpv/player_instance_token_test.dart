import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/player_native.dart';

import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('replacement cores receive distinct initialize and dispose tokens', () async {
    resetSharedPreferencesForTest();
    final initializations = <int>[];
    final disposals = <int>[];
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        if (call.method == 'initialize') {
          initializations.add((call.arguments as Map)['instanceId'] as int);
          return true;
        }
        if (call.method == 'dispose') disposals.add((call.arguments as Map)['instanceId'] as int);
        return null;
      },
      testBody: () async {
        for (var i = 0; i < 3; i++) {
          final player = PlayerNative();
          try {
            await player.open(Media('https://example.test/video-$i.mp4'));
            expect(initializations.last, player.nativeInstanceId);
          } finally {
            await player.dispose();
          }
        }
      },
    );
    expect(initializations.toSet(), hasLength(3));
    expect(initializations.every((id) => id > 0), isTrue);
    expect(disposals, orderedEquals(initializations));
  });
}
