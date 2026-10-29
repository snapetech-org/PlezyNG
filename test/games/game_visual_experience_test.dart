import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/games/game_artwork.dart';
import 'package:plezy/games/game_models.dart';
import 'package:plezy/i18n/presentation_formats.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/games/game_card.dart';
import 'package:plezy/screens/games/game_detail_screen.dart';
import 'package:plezy/screens/games/game_library_view.dart';
import 'package:plezy/screens/games/game_settings_screen.dart';
import 'package:plezy/screens/games/game_stream_status.dart';
import 'package:plezy/screens/games/steam_game_activity_panel.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import '../test_helpers/prefs.dart';

class _Artwork extends GameArtworkLoader {
  final Map<int, Uint8List> covers;
  _Artwork(this.covers);
  @override
  Future<Uint8List?> loadSteam(int appId) async => covers[appId];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final output = Platform.environment['PLEZY_STEAM_VISUAL_DIR'];
  final covers = <int, Uint8List>{};
  final steam = GameHost(id: '101', name: 'Steambox', address: '192.168.1.10', protocol: GameProtocol.steam);
  final desktop = GameHost(id: '102', name: 'Desktop', address: '192.168.1.11', protocol: GameProtocol.steam);
  final bc250 = GameHost(id: '103', name: 'BC250', address: '192.168.1.12', protocol: GameProtocol.steam);
  final catalog = [
    SteamCatalogGame(appId: 620, name: 'Portal 2'),
    SteamCatalogGame(appId: 220, name: 'Half-Life 2'),
    SteamCatalogGame(appId: 413150, name: 'Stardew Valley'),
  ];
  final library = GameLibrary(
    hosts: [steam, desktop, bc250],
    steamCatalog: catalog,
    steamAccountId: '76561198000000000',
    steamCatalogAvailable: true,
    games: [for (final game in catalog) StreamGame(hostKey: steam.key, id: '${game.appId}', name: game.name)],
    favorites: {'steam:620'},
    inventories: [
      for (final host in [steam, desktop, bc250])
        SteamHostInventory(
          hostKey: host.key,
          peerId: 'paired-${host.id}',
          observedAt: DateTime.utc(2026, 10, 29),
          complete: true,
          games: [
            for (final game in catalog)
              if (!(host == bc250 && game.appId == 620))
                SteamInstalledGame(appId: game.appId, name: game.name, installed: true),
          ],
        ),
    ],
  );
  late _Artwork artwork;
  late FocusNode first;

  setUpAll(() async {
    if (output == null) return;
    final fontDir = Platform.environment['PLEZY_STEAM_FONT_DIR'];
    if (fontDir == null) {
      throw StateError('Visual capture requires real Roboto fonts; Ahem is not acceptable evidence.');
    }
    final roboto = FontLoader('Roboto');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      roboto.addFont(File('$fontDir/Roboto-$weight.ttf').readAsBytes().then(ByteData.sublistView));
    }
    await roboto.load();
    final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final family in manifest) {
      if (!['MaterialIcons', 'packages/material_symbols_icons/MaterialSymbolsRounded'].contains(family['family'])) {
        continue;
      }
      final loader = FontLoader(family['family'] as String);
      for (final font in family['fonts'] as List) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
    final coverDir = Platform.environment['PLEZY_STEAM_COVER_DIR'];
    if (coverDir != null) {
      for (final id in [620, 220, 413150]) {
        final file = File('$coverDir/$id.jpg');
        if (await file.exists()) covers[id] = await file.readAsBytes();
      }
    }
  });

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    artwork = _Artwork(covers);
    first = FocusNode();
  });
  tearDown(() {
    artwork.dispose();
    first.dispose();
  });

  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(1280, 900),
    MonoPalette palette = MonoPalette.dark,
    double scale = 1,
    bool rtl = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      InputModeTracker(
        child: RepaintBoundary(
          key: const ValueKey('capture'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: monoTheme(palette).copyWith(
              textTheme: monoTheme(palette).textTheme.apply(fontFamily: output == null ? null : 'Roboto'),
              primaryTextTheme: monoTheme(palette).primaryTextTheme.apply(fontFamily: output == null ? null : 'Roboto'),
              appBarTheme: monoTheme(palette).appBarTheme.copyWith(
                titleTextStyle: monoTheme(
                  palette,
                ).appBarTheme.titleTextStyle?.copyWith(fontFamily: output == null ? null : 'Roboto'),
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
              child: Directionality(textDirection: rtl ? TextDirection.rtl : TextDirection.ltr, child: child!),
            ),
            home: child,
          ),
        ),
      ),
    );
    if (output != null) {
      await tester.runAsync(() async {
        for (final bytes in covers.values) {
          for (final width in [360, 480]) {
            await precacheImage(
              ResizeImage(MemoryImage(bytes), width: width),
              tester.element(find.byType(MaterialApp)),
            );
          }
        }
      });
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (output == null) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('capture')));
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File('$output/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  Widget grid({GameLibrary? state, VoidCallback? connect, void Function(LibraryGame)? controller}) => GameLibraryView(
    library: state ?? library,
    artwork: artwork,
    firstFocus: first,
    onConnections: connect ?? () {},
    onSettings: () {},
    onHelp: () {},
    onLink: () {},
    onRefresh: () {},
    onPlay: (_) {},
    onDetails: (_) {},
    onFavorite: (_) {},
    onMiniPlayer: (_) {},
    onUseAsController: controller,
  );

  for (final variant in [
    (name: 'library-desktop-dark', size: const Size(1280, 900), palette: MonoPalette.dark, scale: 1.0, rtl: false),
    (name: 'library-phone-paper', size: const Size(390, 844), palette: MonoPalette.paper, scale: 1.0, rtl: false),
    (name: 'library-phone-rtl-large', size: const Size(390, 844), palette: MonoPalette.glacier, scale: 2.0, rtl: true),
  ]) {
    testWidgets(variant.name, (tester) async {
      await mount(tester, grid(), size: variant.size, palette: variant.palette, scale: variant.scale, rtl: variant.rtl);
      expect(find.byType(GameCard), findsWidgets);
      if (variant.scale == 2.0) {
        final delegate = tester.widget<SliverGrid>(find.byType(SliverGrid).first).gridDelegate;
        expect((delegate as SliverGridDelegateWithFixedCrossAxisCount).crossAxisCount, lessThan(3));
      }
      await capture(tester, variant.name);
    });
  }

  testWidgets('search and host filters recover without leaving the library', (tester) async {
    await mount(tester, grid());
    await tester.enterText(find.byType(TextField), 'missing game');
    await tester.pumpAndSettle();
    expect(find.text(t.games.clearGameFilters), findsOneWidget);
    await tester.tap(find.text(t.games.clearGameFilters));
    await tester.pumpAndSettle();
    expect(find.byType(GameCard), findsWidgets);
    expect(find.text(t.games.steamBetaTitle), findsNothing);
    expect(find.text(t.games.unlinkSteamAccount), findsNothing);
  });

  testWidgets('controller-only action survives the library presentation split', (tester) async {
    LibraryGame? controlled;
    await mount(tester, grid(controller: (game) => controlled = game));
    await tester.longPress(find.byType(GameCard).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.games.useAsController));
    await tester.pumpAndSettle();
    expect(controlled?.steamAppId, 620);
    expect(tester.takeException(), isNull);
  });

  testWidgets('setup-phone-light', (tester) async {
    var connections = 0;
    await mount(
      tester,
      grid(state: const GameLibrary(), connect: () => connections++),
      size: const Size(390, 844),
      palette: MonoPalette.light,
    );
    await capture(tester, 'setup-phone-light');
    first.requestFocus();
    InputModeTracker.reportNonPointerInput();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(connections, 1);
    await tester.tap(find.text(t.games.findComputers));
    expect(connections, 2);
  });

  for (final rtl in [false, true]) {
    testWidgets('detail actions and availability at large RTL: $rtl', (tester) async {
      var favorites = 0, launches = 0, controllers = 0;
      final game = library.entries.firstWhere((g) => g.steamAppId == 620);
      await mount(
        tester,
        GameDetailScreen(
          game: game,
          artwork: artwork,
          favorite: true,
          preferredRouteKey: game.routes.first.key,
          onFavorite: () => favorites++,
          onPlay: () => launches++,
          onChooseComputer: () {},
          onPlayRoute: (_) => launches++,
          onUseAsController: rtl ? () => controllers++ : null,
          routeActions: (_) => const SizedBox.shrink(),
          activity: SteamGameActivityPanel(appId: 620, isCurrent: () => true, onLink: () {}),
        ),
        size: rtl ? const Size(390, 844) : const Size(1280, 900),
        scale: rtl ? 2 : 1,
        rtl: rtl,
      );
      await capture(tester, rtl ? 'detail-phone-rtl-large' : 'detail-desktop-dark');
      await tester.ensureVisible(find.text(t.games.play));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.games.play));
      expect(launches, 1);
      await tester.ensureVisible(find.text(t.games.unfavorite));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.games.unfavorite));
      expect(favorites, 1);
      if (rtl) {
        await tester.ensureVisible(find.text(t.games.useAsController));
        await tester.pumpAndSettle();
        await tester.tap(find.text(t.games.useAsController));
        expect(controllers, 1);
      }
      await tester.ensureVisible(find.text(isolateDisplayText('BC250')));
      await tester.pumpAndSettle();
      expect(find.textContaining(t.games.notInstalled), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('stream recovery OLED is readable in a small pane with large text', (tester) async {
    var retries = 0;
    final semantics = tester.ensureSemantics();

    await mount(
      tester,
      Scaffold(
        body: GameStreamStatus(
          state: 'failed',
          gameName: 'Portal 2',
          computerName: 'Steambox',
          onReconnect: () => retries++,
          onDisconnect: () {},
        ),
      ),
      size: const Size(390, 600),
      palette: MonoPalette.oled,
      scale: 1.5,
    );
    await capture(tester, 'stream-recovery-oled');
    await tester.ensureVisible(find.text(t.games.reconnect));
    await tester.tap(find.text(t.games.reconnect));
    expect(retries, 1);
    expect(find.bySemanticsLabel(t.games.disconnected), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('streaming settings use their own route', (tester) async {
    await mount(
      tester,
      GameSettingsScreen(profileId: 'visual-fixture', onChooseFolder: () {}),
      size: const Size(800, 900),
    );
    expect(find.text(t.games.streamSettings), findsOneWidget);
    await capture(tester, 'settings-tablet-dark');
    expect(tester.takeException(), isNull);
  });
}
