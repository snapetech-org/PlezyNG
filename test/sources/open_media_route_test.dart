import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/mpv/player/video_rect_support.dart';
import 'package:plezy/multiview/workspace_controller.dart';
import 'package:plezy/screens/sources/open_media_screen.dart';
import 'package:plezy/screens/sources/source_player_screen.dart';
import 'package:plezy/services/deep_links/deep_link.dart';
import 'package:plezy/services/deep_links/deep_link_launcher.dart';
import 'package:plezy/services/playback_coordinator.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/sources/source_controller.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:plezy/sources/source_playback.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../services/music/music_playback_service_test.dart' show FakePlayer, FakeMediaControlsManager;
import '../test_helpers/prefs.dart';
import 'fixtures/memory_sources.dart';

class _VideoPlayer extends FakePlayer implements VideoRectSupport {
  bool frameReady = false;
  final rectangles = <Rect>[];

  @override
  PlayerState get state =>
      super.state.copyWith(hasRenderedFrame: frameReady, seekable: true, duration: const Duration(seconds: 180));

  @override
  Future<void> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
  }) async {
    await super.open(media, play: play, isLive: isLive);
    // Match the native ordering: decoding completes inside SourcePlayback.start,
    // before OpenMedia pushes its player route. No later restart/seek rescues it.
    frameReady = true;
    durationCtrl.add(const Duration(seconds: 180));
    playbackRestartCtrl.add(null);
  }

  @override
  Future<void> setVideoRect({
    required int left,
    required int top,
    required int right,
    required int bottom,
    required double devicePixelRatio,
  }) async {
    rectangles.add(Rect.fromLTRB(left.toDouble(), top.toDouble(), right.toDouble(), bottom.toDouble()));
  }

  @override
  void reportVideoRectError(PlayerError error) => errorCtrl.add(error);
}

class _Controls extends FakeMediaControlsManager {
  @override
  Future<void> setBackgroundMode(bool enabled) async {}

  @override
  Future<void> updateFileMetadata({
    required String title,
    String? author,
    String? album,
    Duration? duration,
    Uint8List? artwork,
  }) async {
    metadataTitles.add(title);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SourceDatabase database;
  late MemorySources sources;
  late SourcePlayback playback;
  late _VideoPlayer native;
  late _Controls controls;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
    PlaybackCoordinator.instance
      ..setWorkspaceVideoSessionCount(0)
      ..setWorkspaceVideoPlayerSlots(const []);
    directory = await Directory.systemTemp.createTemp('pleazyng-open-media-route-');
    database = SourceDatabase(NativeDatabase.memory());
    sources = MemorySources(SourceRepository(database), directory);
    await sources.repository.preference(sources.profileId!, 'universal-media-favorites-v1');
    native = _VideoPlayer();
    controls = _Controls();
    playback = SourcePlayback(
      sources,
      playerFactory: (_) => native,
      controlsFactory: () => controls,
      wakelockToggle: (_) async {},
    );
  });

  tearDown(() async {
    await playback.stop();
    playback.dispose();
    await playback.stop();
    native.closeControllers();
    controls.closeControllers();
    sources.dispose();
    await database.close();
    await directory.delete(recursive: true);
    SettingsService.resetForTesting();
    PlaybackCoordinator.instance
      ..setWorkspaceVideoSessionCount(0)
      ..setWorkspaceVideoPlayerSlots(const []);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> closeRoute(WidgetTester tester) async {
    // SourcePlayer owns a final stop on disposal. Keep that disposal and the
    // real gateway/Drift teardown on the same real-I/O clock as its start.
    await tester.runAsync(() async {
      await playback.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      await playback.stop();
    });
  }

  Future<void> openAndPlay(
    WidgetTester tester, {
    MultiviewWorkspaceController? workspace,
    bool deepLink = false,
  }) async {
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final capture = GlobalKey();
    const address = 'https://media.example/movie.mp4';
    Widget content = Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () {
            if (deepLink) {
              unawaited(launchDeepLink(context, const OpenMediaLink(address: address), isOffline: false));
            } else {
              unawaited(
                Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => const OpenMediaScreen(initialAddress: address))),
              );
            }
          },
          child: const Text('Open media route'),
        ),
      ),
    );
    if (workspace != null) {
      final profileHome = content;
      content = ChangeNotifierProvider.value(
        value: workspace,
        child: Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => profileHome)),
      );
    }
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SourceController>.value(value: sources),
          ChangeNotifierProvider<SourcePlayback>.value(value: playback),
        ],
        child: InputModeTracker(
          child: RepaintBoundary(
            key: capture,
            child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: content),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open media route'));
    await settle(tester);
    expect(find.byType(OpenMediaScreen), findsOneWidget);
    await tester.ensureVisible(find.text(t.universalMedia.liveStream));
    await tester.tap(find.text(t.universalMedia.liveStream));
    await tester.ensureVisible(find.text(t.universalMedia.playNow));
    await tester.runAsync(() async {
      await tester.tap(find.text(t.universalMedia.playNow));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while ((native.openedUris.isEmpty || playback.opening) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(SourcePlayerScreen), findsOneWidget);
    expect(native.openedUris, hasLength(1));
    expect(Uri.parse(native.openedUris.single).host, '127.0.0.1');
    expect(playback.isTransientInput, isTrue);
    expect(playback.player, same(native));
    expect(native.state.hasRenderedFrame, isTrue);
    expect(native.seeks, isEmpty);
    expect(native.rectangles, isNotEmpty);
    final video = find.byType(Video).first;
    expect(video, findsOneWidget);
    final point = tester.getCenter(video);
    final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = (await tester.runAsync(() => boundary.toImage()))!;
    final pixels = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    expect(
      pixels.getUint8((point.dy.toInt() * image.width + point.dx.toInt()) * 4 + 3),
      0,
      reason: 'The already-rendered native plane must be revealed on the first route mount.',
    );
    image.dispose();
    final mini = find.byTooltip(t.videoControls.openMiniPlayer);
    expect(mini, workspace == null ? findsNothing : findsOneWidget);
    if (workspace != null) {
      expect(tester.element(find.byType(SourcePlayerScreen)).read<MultiviewWorkspaceController>(), same(workspace));
    }
    final beforePause = native.pauseCalls;
    await tester.runAsync(() async {
      await tester.ensureVisible(find.byTooltip(t.fileSources.pause));
      await tester.tap(find.byTooltip(t.fileSources.pause));
    });
    await settle(tester);
    expect(native.pauseCalls, beforePause + 1);
    await tester.runAsync(() => tester.tap(find.byTooltip(t.fileSources.play)));
    await settle(tester);
    expect(tester.takeException(), isNull);
    if (workspace != null) {
      await tester.runAsync(() => tester.tap(mini));
      await settle(tester);
      expect(workspace.sessionCount, 1);
      expect(playback.player, same(native));
      expect(native.openedUris, hasLength(1));
    }
    await closeRoute(tester);
    if (workspace != null) expect(workspace.sessionCount, 0);
    expect(playback.active, isFalse);
  }

  testWidgets('ordinary OpenMedia Play reveals the native plane without an optional workspace', (tester) async {
    try {
      await openAndPlay(tester);
    } finally {
      await closeRoute(tester);
    }
  });

  testWidgets('standalone OpenMedia app link plays without a profile workspace', (tester) async {
    try {
      await openAndPlay(tester, deepLink: true);
    } finally {
      await closeRoute(tester);
    }
  });

  testWidgets('profile app link retains its existing workspace across both player routes', (tester) async {
    final workspace = MultiviewWorkspaceController();
    try {
      await openAndPlay(tester, workspace: workspace, deepLink: true);
    } finally {
      await closeRoute(tester);
      workspace.dispose();
    }
  });
}
