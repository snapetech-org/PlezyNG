import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/player_native.dart';
import 'package:plezy/mpv/player/platform/player_android.dart';
import 'package:plezy/mpv/player/platform/player_linux.dart';
import 'package:plezy/mpv/player/platform/player_windows.dart';
import 'package:plezy/widgets/overlay_sheet.dart';
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

  for (final backend in [
    (name: 'Linux', create: PlayerLinux.new, channel: 'mpv_player'),
    (name: 'Windows', create: PlayerWindows.new, channel: 'mpv_player'),
    (name: 'Apple/mpv', create: PlayerNative.new, channel: 'mpv_player'),
    (name: 'Android/ExoPlayer', create: PlayerAndroid.new, channel: 'exo_player'),
  ]) {
    testWidgets('${backend.name} clears the retained home route throughout resumed playback', (tester) async {
      await withMockPlayerChannels(
        methodChannelName: 'com.plezy/${backend.channel}',
        eventChannelName: 'com.plezy/${backend.channel}/events',
        methodHandler: (call) async => call.method == 'initialize' ? true : null,
        testBody: () async {
          final player = backend.create();
          final firstFrame = ValueNotifier(false);
          final capture = GlobalKey();
          final navigator = GlobalKey<NavigatorState>();
          final artwork = ValueNotifier(Colors.red);
          try {
            await tester.pumpWidget(
              RepaintBoundary(
                key: capture,
                child: MaterialApp(
                  navigatorKey: navigator,
                  home: ValueListenableBuilder<Color>(
                    valueListenable: artwork,
                    builder: (_, color, _) => ColoredBox(color: color),
                  ),
                ),
              ),
            );
            unawaited(
              VideoPlayerRoute(
                builder: (_) => OverlaySheetHost(
                  child: Scaffold(
                    backgroundColor: Colors.transparent,
                    body: Stack(
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
                  ),
                ),
              ).push(navigator.currentState!),
            );
            await tester.pumpAndSettle();
            Future<int> pixel(int x, int y) async {
              final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
              final image = (await tester.runAsync(() => boundary.toImage()))!;
              final data = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
              final offset = (y * image.width + x) * 4;
              final result = Color.fromARGB(
                data.getUint8(offset + 3),
                data.getUint8(offset),
                data.getUint8(offset + 1),
                data.getUint8(offset + 2),
              );
              image.dispose();
              return result.toARGB32();
            }

            expect(await pixel(50, 50), Colors.black.toARGB32());
            // The screen releases its startup cover after resume and display setup.
            firstFrame.value = true;
            await tester.pump();
            expect(await pixel(50, 50), Colors.transparent.toARGB32());
            expect(await pixel(25, 25), Colors.blue.toARGB32());
            expect(await pixel(5, 5), Colors.red.toARGB32());
            // Home keeps repainting below a non-opaque player route (e.g. its hero
            // carousel advances). It must never cover the native video plane again.
            artwork.value = Colors.green;
            await tester.pump();
            expect(await pixel(50, 50), Colors.transparent.toARGB32());
            expect(await pixel(25, 25), Colors.blue.toARGB32());

            // An episode/source reload reinstates black until its own first frame.
            firstFrame.value = false;
            await tester.pump();
            expect(await pixel(50, 50), Colors.black.toARGB32());
            firstFrame.value = true;
            await tester.pump();
            expect(await pixel(50, 50), Colors.transparent.toARGB32());

            navigator.currentState!.pop();
            await tester.pumpAndSettle();
            expect(await pixel(50, 50), Colors.green.toARGB32());
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(() => player.dispose());
            firstFrame.dispose();
            artwork.dispose();
          }
        },
      );
    });
  }

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
