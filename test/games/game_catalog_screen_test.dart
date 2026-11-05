import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/games/game_library_controller.dart';
import 'package:plezy/games/game_models.dart';
import 'package:plezy/games/game_streaming_client.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/screens/games/game_card.dart';
import 'package:plezy/screens/games/game_detail_screen.dart';
import 'package:plezy/screens/games/games_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/sources/source_controller.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import '../test_helpers/prefs.dart';

class _Profile extends ChangeNotifier implements ActiveProfileProvider {
  @override
  String? activeId = 'alice';
  void switchTo(String id) {
    activeId = id;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sources extends ChangeNotifier implements SourceController {
  _Sources(this.repository);
  @override
  final SourceRepository repository;
  @override
  Future<void> get ready => Future.value();
  @override
  String? profileId = 'alice';
  @override
  int generation = 1;
  @override
  bool blocked = false;
  @override
  bool current(int epoch) => epoch == generation;
  @override
  void requireSession([int? epoch]) {}
  void switchTo(String id) {
    profileId = id;
    generation++;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('browse-only platform loads the persisted catalog and retires profile-owned details', (tester) async {
    resetSharedPreferencesForTest();
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.showGamesTabForProfile('alice'), true);
    await settings.write(SettingsService.showGamesTabForProfile('bob'), true);
    final db = SourceDatabase(NativeDatabase.memory());
    final repository = SourceRepository(db);
    final profile = _Profile();
    final sources = _Sources(repository);
    addTearDown(profile.dispose);
    addTearDown(sources.dispose);
    addTearDown(db.close);
    final nativeCalls = <String>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(NativeGameStreamingClient.channel, (MethodCall call) async {
      nativeCalls.add(call.method);
      throw MissingPluginException();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(NativeGameStreamingClient.channel, null));
    await tester.runAsync(
      () => repository.savePreference(
        'alice',
        GameLibraryController.preferenceKey,
        GameLibrary(
          steamAccountId: '76561198000000000',
          steamCatalogAvailable: true,
          steamCatalog: [SteamCatalogGame(appId: 620, name: 'Portal 2')],
        ).toJson(),
      ),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ActiveProfileProvider>.value(value: profile),
          ChangeNotifierProvider<SourceController>.value(value: sources),
        ],
        child: InputModeTracker(
          child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const GamesScreen()),
        ),
      ),
    );
    for (var i = 0; i < 50 && find.byType(GameCard).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byType(GameCard), findsOneWidget);
    expect(find.text(t.games.browseOnlyTitle), findsOneWidget);
    expect(find.byTooltip(t.games.streamSettings), findsNothing);
    await tester.tap(find.byType(GameCard));
    await tester.pumpAndSettle();
    expect(find.byType(GameDetailScreen), findsOneWidget);
    expect(find.text(t.games.play), findsNothing);
    await tester.ensureVisible(find.text(t.games.favorite));
    await tester.tap(find.text(t.games.favorite));
    for (var i = 0; i < 50 && find.text(t.games.unfavorite).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.text(t.games.unfavorite), findsOneWidget);
    final saved = await tester.runAsync(() => repository.preference('alice', GameLibraryController.preferenceKey));
    expect(GameLibrary.fromJson(saved!).favoriteKeys, contains('steam:620'));
    sources.switchTo('bob');
    profile.switchTo('bob');
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byType(GameDetailScreen), findsNothing);
    expect(find.text('Portal 2'), findsNothing);
    expect(nativeCalls.where((method) => method != 'cancel'), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }, skip: !PlatformDetector.isWebOSBuild() && !PlatformDetector.isTizenBuild());
}
