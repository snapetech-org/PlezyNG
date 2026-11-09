import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/player_native.dart';
import 'package:plezy/mpv/video.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/video_player_navigation.dart';

import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  tearDown(SettingsService.resetForTesting);

  testWidgets('native video clears underlying artwork only after its first frame', (tester) async {
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async => call.method == 'initialize' ? true : null,
      testBody: () async {
        final player = PlayerNative();
        final firstFrame = ValueNotifier(false);
        final capture = GlobalKey();
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              navigatorKey: navigator,
              home: const ColoredBox(color: Colors.red),
            ),
          ),
        );
        unawaited(
          VideoPlayerRoute(
            builder: (_) => Stack(
              children: [
                Positioned(
                  left: 20,
                  top: 20,
                  width: 100,
                  height: 100,
                  child: Video(
                    player: player,
                    hasFirstFrame: firstFrame,
                    controls: (_) => const Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(width: 10, height: 10, child: ColoredBox(color: Colors.blue)),
                    ),
                  ),
                ),
              ],
            ),
          ).push(navigator.currentState!),
        );
        await tester.pumpAndSettle();
        Future<int> alpha(int x, int y) async {
          final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = (await tester.runAsync(() => boundary.toImage()))!;
          final data = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
          final result = data.getUint8((y * image.width + x) * 4 + 3);
          image.dispose();
          return result;
        }

        expect(await alpha(50, 50), 255);
        firstFrame.value = true;
        await tester.pump();
        expect(await alpha(50, 50), 0);
        expect(await alpha(25, 25), 255);
        expect(await alpha(5, 5), 255);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => player.dispose());
        firstFrame.dispose();
      },
    );
  });

  testWidgets('Video reports updated physical pane bounds when workspace layout moves', (tester) async {
    final rectCalls = <Map<Object?, Object?>>[];
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        if (call.method == 'setVideoRect') {
          rectCalls.add(call.arguments as Map<Object?, Object?>);
        }
        if (call.method == 'initialize') return true;
        return null;
      },
      testBody: () async {
        final player = PlayerNative();
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(devicePixelRatio: 2),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 300, height: 200, child: Video(player: player)),
              ),
            ),
          ),
        );
        await tester.pump();
        await player.open(Media('https://example.test/video.mp4'), play: false);

        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(devicePixelRatio: 2),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 20, top: 10),
                  child: SizedBox(width: 300, height: 200, child: Video(player: player)),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(rectCalls, hasLength(2));
        expect(rectCalls.first, {'left': 0, 'top': 0, 'right': 600, 'bottom': 400, 'devicePixelRatio': 2.0});
        expect(rectCalls.last, {'left': 40, 'top': 20, 'right': 640, 'bottom': 420, 'devicePixelRatio': 2.0});
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(() => player.dispose());
      },
    );
  });
}
