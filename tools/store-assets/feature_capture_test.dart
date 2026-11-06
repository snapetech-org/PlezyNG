// Opt-in captures of production feature screens with populated local fixtures.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:plezy/games/game_models.dart';
import 'package:plezy/games/steam_input_profile.dart';
import 'package:plezy/games/steam_touch_layout.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/multiview/workspace_controller.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/trackers_provider.dart';
import 'package:plezy/screens/discovery/discovery_controls.dart';
import 'package:plezy/screens/discovery/discovery_deck_view.dart';
import 'package:plezy/screens/games/game_library_view.dart';
import 'package:plezy/screens/games/steam_input_dialog.dart';
import 'package:plezy/screens/games/steam_touch_layout_dialog.dart';
import 'package:plezy/screens/music/now_playing_screen.dart';
import 'package:plezy/screens/sources/source_detail_screen.dart';
import 'package:plezy/screens/sources/source_player_screen.dart';
import 'package:plezy/screens/sources/sources_screen.dart';
import 'package:plezy/screens/sources/open_media_screen.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/image_cache_service.dart';
import 'package:plezy/widgets/optimized_media_image.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/sources/source_controller.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_playback.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/overlay_sheet.dart';
import 'package:plezy/widgets/video_controls/sheets/subtitle_ai_sheet.dart';
import '../../test/appearance/appearance_fixtures.dart';
import '../../test/test_helpers/multi_server_fixtures.dart';
import '../../test/test_helpers/prefs.dart';
import 'feature_fixtures.dart';
import 'package:plezy/screens/games/steam_touch_controls.dart';
import 'feature_workspace.dart';
import 'feature_live_tv.dart';
import 'package:plezy/screens/livetv/tabs/guide_tab.dart';
import 'package:plezy/services/visualization/visualizer_pack_store.dart';
import 'package:plezy/services/visualization/visualizer_session.dart';
import 'package:plezy/widgets/music/visualizer_preset_browser.dart';

void main() {
  final output = Platform.environment['PLEAZYNG_FEATURE_OUTPUT'];
  if (output == null) return;
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer artworkServer;
  late HttpOverrides? overrides;
  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => (Directory('$output/cache')..createSync(recursive: true)).path,
    );
    overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    artworkServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    artworkServer.listen((request) async {
      final file = File('tools/store-assets/fixtures/features/${request.uri.pathSegments.last}');
      if (!file.existsSync()) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType('image', 'jpeg');
      request.response.add(file.readAsBytesSync());
      await request.response.close();
    });
    await initializeDateFormatting('en');
    await (FontLoader('Appearance Sans')..addFont(rootBundle.load('assets/go-noto-current-regular.ttf'))).load();
    for (final family in ['Rounded', 'Outlined', 'Sharp']) {
      await (FontLoader(
        'packages/material_symbols_icons/MaterialSymbols$family',
      )..addFont(rootBundle.load('packages/material_symbols_icons/lib/fonts/MaterialSymbols$family.ttf'))).load();
    }
  });
  tearDownAll(() async {
    await artworkServer.close(force: true);
    HttpOverrides.global = overrides;
  });
  final scenes = [
    'book-library-detail',
    'audiobook-player',
    'podcast-player',
    'music-player',
    'steam-library',
    'steam-controller-layout',
    'steam-touch-layout',
    'steam-touch-game',
    'connected-sources',
    'open-media',
    'find-your-next',
    'subtitle-ai',
    'multiview',
    'live-tv-guide',
    'visualizer-library',
  ];
  for (final scene in scenes) {
    testWidgets('feature $scene', (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        resetSharedPreferencesForTest();
        SettingsService.resetForTesting();
        await SettingsService.getInstance();
        LocaleSettings.setLocaleSync(AppLocale.en);
        final phone =
            scene == 'audiobook-player' ||
            scene == 'podcast-player' ||
            scene == 'open-media' ||
            scene == 'steam-controller-layout';
        final landscapePhone = scene == 'steam-touch-layout' || scene == 'steam-touch-game';
        PlatformDetector.debugSetIsDesktopOSOverride(!phone && !landscapePhone);
        TvDetectionService.debugSetAppleTVOverride(false);
        addTearDown(() => PlatformDetector.debugSetIsDesktopOSOverride(null));
        addTearDown(TvDetectionService.debugReset);
        tester.view.devicePixelRatio = phone || landscapePhone ? 2 : 1.5;
        tester.view.physicalSize = phone
            ? const Size(1080, 2400)
            : landscapePhone
            ? const Size(2400, 1080)
            : const Size(1920, 1350);
        addTearDown(tester.view.reset);
        final directory = Directory('$output/state-$scene')..createSync(recursive: true);
        final db = SourceDatabase(NativeDatabase.memory());
        final sources = FeatureSources(SourceRepository(db), directory);
        sources.sources = [
          const FileSource(
            id: 'gallery-books',
            profileId: 'alice',
            kind: FileSourceKind.opds,
            name: 'The Reading Room',
          ),
          const FileSource(
            id: 'gallery-audio',
            profileId: 'alice',
            kind: FileSourceKind.audiobookshelf,
            name: 'Audiobookshelf',
          ),
          const FileSource(id: 'gallery-nas', profileId: 'alice', kind: FileSourceKind.smb, name: 'Home media NAS'),
          const FileSource(
            id: 'gallery-drive',
            profileId: 'alice',
            kind: FileSourceKind.googleDrive,
            name: 'Google Drive',
          ),
        ];
        final player = FeaturePlayer();
        final playback = FeaturePlayback(player, scene == 'podcast-player' ? featurePodcast : featureBook, sources);
        final manager = MultiServerManager();
        final multiServer = testMultiServerProvider(manager);
        if (scene == 'live-tv-guide') {
          manager.debugRegisterClientForTesting(FeatureLiveClient());
          multiServer.debugSetLiveTvServersForTesting([
            LiveTvServerInfo(serverId: 'gallery-tv', dvrKey: 'gallery-dvr'),
          ]);
        }
        final workspace = MultiviewWorkspaceController();
        final music = FeatureMusic('http://127.0.0.1:${artworkServer.port}');
        final artwork = FeatureGameArtwork();
        final presetStore = VisualizerPackStore(profileId: 'gallery');
        addTearDown(presetStore.dispose);
        final focus = FocusNode();
        addTearDown(() async {
          playback.dispose();
          sources.dispose();
          music.dispose();
          artwork.dispose();
          workspace.dispose();
          multiServer.dispose();
          manager.dispose();
          focus.dispose();
          await db.close();
        });
        // Prime local file images in the real async zone before production Image.file widgets mount.
        await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
        await tester.runAsync(() async {
          if (scene == 'music-player') {
            final url = music.currentTrack.thumbPath!;
            await PlexImageCacheManager.instance.putFile(
              url,
              File('tools/store-assets/fixtures/features/blue-hour.jpg').readAsBytesSync(),
              key: 'plex_optimized_${sha1.convert(utf8.encode(url))}',
              fileExtension: 'jpg',
            );
          }
          for (final name in ['night-library', 'signal-story', 'blue-hour']) {
            await precacheImage(
              FileImage(File('tools/store-assets/fixtures/features/$name.jpg')),
              tester.element(find.byType(Scaffold)),
            );
          }
        });
        final host = GameHost(
          id: 'gallery-desktop',
          name: 'Living room PC',
          address: '192.0.2.10',
          protocol: GameProtocol.steam,
        );
        final games = [
          for (final (id, name) in [(620, 'Portal 2'), (413150, 'Stardew Valley'), (1145360, 'Hades')])
            StreamGame(hostKey: host.key, id: '$id', name: name),
        ];
        final library = GameLibrary(
          hosts: [host],
          games: games,
          steamAccountId: '76561198000000000',
          steamCatalogAvailable: true,
          steamCatalog: [for (final game in games) SteamCatalogGame(appId: int.parse(game.id), name: game.name)],
          inventories: [
            SteamHostInventory(
              hostKey: host.key,
              peerId: 'gallery-peer',
              observedAt: DateTime(2026, 11, 5),
              games: [
                for (final game in games)
                  SteamInstalledGame(appId: int.parse(game.id), name: game.name, installed: true),
              ],
              complete: true,
            ),
          ],
        );
        final widget = switch (scene) {
          'multiview' => FeatureWorkspace(
            controller: workspace,
            readerImage: '$output/ebook-workspace-surface-dark.png',
          ),
          'live-tv-guide' => Scaffold(
            appBar: AppBar(title: const Text('Live TV')),
            body: GuideTab(channels: featureChannels),
          ),
          'visualizer-library' => Scaffold(
            body: VisualizerPresetBrowser(
              presets: [
                for (final (i, title) in [
                  'Coral Orbit',
                  'Prism Tide',
                  'Night Drive',
                  'Northern Lights',
                  'Open Water',
                  'Afterglow',
                ].indexed)
                  VisualizerPresetFile(
                    id: 'preset-$i',
                    title: title,
                    path: '${directory.path}/$title.milk',
                    root: directory.path,
                    libraryPath: '$title.milk',
                    packName: 'North Coast',
                    author: 'Pleazyng',
                    tags: const ['ambient', 'color'],
                    license: 'CC0',
                  ),
              ],
              store: presetStore,
              capability: const VisualizerCapabilities(available: true, reason: '', engine: 'projectm'),
            ),
          ),
          'book-library-detail' => const SourceDetailScreen(entry: featureBook),
          'audiobook-player' || 'podcast-player' => const SourcePlayerScreen(),
          'music-player' => const NowPlayingScreen(),
          'steam-library' => GameLibraryView(
            library: library,
            artwork: artwork,
            firstFocus: focus,
            onConnections: () {},
            onSettings: () {},
            onHelp: () {},
            onLink: () {},
            onRefresh: () {},
            onPlay: (_) {},
            onDetails: (_) {},
            onFavorite: (_) {},
            onMiniPlayer: (_) {},
          ),
          'steam-controller-layout' => Scaffold(
            body: SteamInputDialog(
              initial: SteamInputProfile.defaults(),
              players: 4,
              isCurrent: () => true,
              apply: (_) async {},
            ),
          ),
          'steam-touch-game' => Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(
                  File('tools/store-assets/fixtures/games/stardew-gameplay.jpg').readAsBytesSync(),
                  fit: BoxFit.contain,
                ),
                SteamTouchControls(onButton: (_, _) {}, onStick: (_, _) {}, onRelease: () {}),
              ],
            ),
          ),
          'steam-touch-layout' => SteamTouchLayoutDialog(initial: SteamTouchLayout()),
          'connected-sources' => const SourcesScreen(),
          'open-media' => const OpenMediaScreen(initialAddress: 'https://media.example.org/films/caminandes.mp4'),
          'subtitle-ai' => OverlaySheetHost(
            child: Scaffold(
              body: Center(
                child: SizedBox(width: 800, child: SubtitleAiSheet(player: player)),
              ),
            ),
          ),
          _ => Scaffold(
            appBar: AppBar(title: const Text('Find your next')),
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: DiscoveryDeckView(
                choiceId: 'night-library',
                title: 'The Night Library',
                subtitle: 'Nora Vale · Books',
                facts: '2026 · Mystery · Adventure',
                summary: featureBook.description,
                artwork: Image.memory(
                  File('tools/store-assets/fixtures/features/night-library.jpg').readAsBytesSync(),
                  fit: BoxFit.cover,
                ),
                artworkAspectRatio: 2 / 3,
                enabled: true,
                onSave: () {},
                onSkip: () {},
                onDetails: () {},
                actions: DiscoveryActionBar(
                  primaryLabel: 'Read',
                  primaryIcon: Symbols.menu_book_rounded,
                  onSkip: () {},
                  onSave: () {},
                  onOpen: () {},
                  onDetails: () {},
                ),
              ),
            ),
          ),
        };
        const key = Key('feature-capture');
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<SourceController>.value(value: sources),
              ChangeNotifierProvider<SourcePlayback>.value(value: playback),
              ChangeNotifierProvider<MultiServerProvider>.value(value: multiServer),
              ChangeNotifierProvider<MusicPlaybackService>.value(value: music),
              ChangeNotifierProvider<MultiviewWorkspaceController>.value(value: workspace),
              ChangeNotifierProvider(create: (_) => TrackersProvider()),
              ChangeNotifierProvider(create: (_) => HiddenLibrariesProvider(profileId: 'alice')),
            ],
            child: RepaintBoundary(
              key: key,
              child: appearanceApp(
                loadFonts: true,
                platform: phone ? TargetPlatform.android : TargetPlatform.linux,
                child: widget,
              ),
            ),
          ),
        );
        await tester.pump();
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (scene == 'music-player') {
          final images = tester.widgetList<OptimizedMediaImage>(find.byType(OptimizedMediaImage)).toList();
          expect(images.any((image) => image.imagePath == music.currentTrack.thumbPath), isTrue);
        }
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
          final image = await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          File('$output/$scene-dark.png').writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }, _FeatureNetwork());
    });
  }
}

class _FeatureNetwork extends HttpOverrides {}
