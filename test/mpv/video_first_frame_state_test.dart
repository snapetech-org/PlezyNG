import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/player_base.dart';
import 'package:plezy/mpv/player/player_native.dart';
import 'package:plezy/mpv/player/platform/player_android.dart';
import 'package:plezy/mpv/player/platform/player_linux.dart';
import 'package:plezy/mpv/player/platform/player_windows.dart';
import 'package:plezy/mpv/video.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';

Future<int> pixel(WidgetTester tester, GlobalKey capture, int x, int y) async {
  final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync(() => boundary.toImage()))!;
  final data = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
  final offset = (y * image.width + x) * 4;
  final color = Color.fromARGB(
    data.getUint8(offset + 3),
    data.getUint8(offset),
    data.getUint8(offset + 1),
    data.getUint8(offset + 2),
  );
  image.dispose();
  return color.toARGB32();
}

Widget surface(PlayerBase player, {ValueNotifier<bool>? firstFrame}) => Directionality(
  textDirection: TextDirection.ltr,
  child: SizedBox.expand(
    child: Video(
      player: player,
      hasFirstFrame: firstFrame,
      controls: (_) => const Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 10, height: 10, child: ColoredBox(color: Colors.blue)),
      ),
    ),
  ),
);

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
    Future<void> withPlayer(WidgetTester tester, Future<void> Function(PlayerBase) body) => withMockPlayerChannels(
      methodChannelName: 'com.plezy/${backend.channel}',
      eventChannelName: 'com.plezy/${backend.channel}/events',
      testBody: () => withMockPlayerChannels(
        methodChannelName: 'com.plezy/${backend.channel}/workspace',
        eventChannelName: 'com.plezy/${backend.channel}/workspace/events',
        testBody: () async {
          final player = backend.create();
          try {
            await body(player);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(() => player.dispose());
          }
        },
      ),
    );

    testWidgets('${backend.name} late mount reveals a frame rendered before an ordinary player route', (tester) async {
      await withPlayer(tester, (player) async {
        final capture = GlobalKey();
        final navigator = GlobalKey<NavigatorState>();
        // SourcePlayback starts before SourcePlayerScreen is pushed. Deliver
        // the real player event before Video exists, and drain the broadcast.
        player.handlePlayerEvent('playback-restart', null);
        await tester.pumpAndSettle();
        expect(player.state.hasRenderedFrame, isTrue);
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
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                backgroundColor: Colors.green,
                body: Stack(children: [Positioned(left: 20, top: 20, width: 100, height: 100, child: surface(player))]),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(await pixel(tester, capture, 50, 50), Colors.transparent.toARGB32());
        expect(await pixel(tester, capture, 25, 25), Colors.blue.toARGB32());
        expect(await pixel(tester, capture, 5, 5), Colors.green.toARGB32());
        await tester.pumpWidget(const SizedBox.shrink());
      });
    });

    testWidgets('${backend.name} late mount ignores an earlier load frame after reset', (tester) async {
      await withPlayer(tester, (player) async {
        final capture = GlobalKey();
        player.handlePlayerEvent('playback-restart', null);
        player.handlePlayerEvent('file-loaded', null);
        await tester.pumpAndSettle();
        expect(player.state.hasRenderedFrame, isFalse);
        await tester.pumpWidget(RepaintBoundary(key: capture, child: surface(player)));
        expect(await pixel(tester, capture, 50, 50), Colors.black.toARGB32());
        player.handlePlayerEvent('playback-restart', null);
        await tester.pumpAndSettle();
        expect(await pixel(tester, capture, 50, 50), Colors.transparent.toARGB32());
        await tester.pumpWidget(const SizedBox.shrink());
      });
    });

    testWidgets('${backend.name} replacement uses only the new player current frame', (tester) async {
      await withPlayer(tester, (player) async {
        final replacement = backend.create(companionSession: true);
        final capture = GlobalKey();
        try {
          player.handlePlayerEvent('playback-restart', null);
          await tester.pumpAndSettle();
          await tester.pumpWidget(RepaintBoundary(key: capture, child: surface(player)));
          expect(await pixel(tester, capture, 50, 50), Colors.transparent.toARGB32());
          await tester.pumpWidget(RepaintBoundary(key: capture, child: surface(replacement)));
          expect(await pixel(tester, capture, 50, 50), Colors.black.toARGB32());
          player.handlePlayerEvent('playback-restart', null);
          await tester.pumpAndSettle();
          expect(await pixel(tester, capture, 50, 50), Colors.black.toARGB32());
          replacement.handlePlayerEvent('playback-restart', null);
          await tester.pumpAndSettle();
          expect(await pixel(tester, capture, 50, 50), Colors.transparent.toARGB32());
          player.handlePlayerEvent('file-loaded', null);
          await tester.pumpAndSettle();
          await tester.pumpWidget(RepaintBoundary(key: capture, child: surface(player)));
          expect(await pixel(tester, capture, 50, 50), Colors.black.toARGB32());
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() => replacement.dispose());
        }
      });
    });

    testWidgets('${backend.name} queued restart cannot reveal a newer reset load', (tester) async {
      await withPlayer(tester, (player) async {
        final capture = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(key: capture, child: surface(player)));
        // The stream is asynchronous. A newer load can reset its snapshot
        // before the previous restart reaches Video's listener.
        player.handlePlayerEvent('playback-restart', null);
        player.handlePlayerEvent('file-loaded', null);
        await tester.pumpAndSettle();
        expect(player.state.hasRenderedFrame, isFalse);
        expect(await pixel(tester, capture, 50, 50), Colors.black.toARGB32());
        player.handlePlayerEvent('playback-restart', null);
        await tester.pumpAndSettle();
        expect(await pixel(tester, capture, 50, 50), Colors.transparent.toARGB32());
        await tester.pumpWidget(const SizedBox.shrink());
      });
    });

    testWidgets('${backend.name} explicit first-frame hold overrides rendered state and binding changes', (
      tester,
    ) async {
      await withPlayer(tester, (player) async {
        final firstFrame = ValueNotifier(false);
        final capture = GlobalKey();
        try {
          player.handlePlayerEvent('playback-restart', null);
          await tester.pumpAndSettle();
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: surface(player, firstFrame: firstFrame),
            ),
          );
          expect(await pixel(tester, capture, 50, 50), Colors.black.toARGB32());
          player.handlePlayerEvent('playback-restart', null);
          await tester.pumpAndSettle();
          expect(await pixel(tester, capture, 50, 50), Colors.black.toARGB32());
          firstFrame.value = true;
          await tester.pumpAndSettle();
          expect(await pixel(tester, capture, 50, 50), Colors.transparent.toARGB32());
          firstFrame.value = false;
          await tester.pumpAndSettle();
          expect(await pixel(tester, capture, 50, 50), Colors.black.toARGB32());
          await tester.pumpWidget(RepaintBoundary(key: capture, child: surface(player)));
          expect(await pixel(tester, capture, 50, 50), Colors.transparent.toARGB32());
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: surface(player, firstFrame: firstFrame),
            ),
          );
          expect(await pixel(tester, capture, 50, 50), Colors.black.toARGB32());
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          firstFrame.dispose();
        }
      });
    });
  }
}
