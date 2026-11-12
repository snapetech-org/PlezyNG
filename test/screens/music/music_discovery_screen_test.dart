import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/music/music_discovery_screen.dart';
import 'package:plezy/services/music/music_discovery.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';
import '../../test_helpers/music_experience_fakes.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

class _Profile extends ChangeNotifier implements ActiveProfileProvider {
  @override
  String get activeId => 'p';
  @override
  bool isBinding = false;
  @override
  bool lastBindingSucceeded = true;
  @override
  int identityMutationGeneration = 1;
  void refresh() => notifyListeners();
  void retire() {
    identityMutationGeneration++;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends ExperienceClient {
  final constraints = <(int, double)>[];
  @override
  Future<List<MediaItem>> sonicPath({
    required String libraryId,
    required String startId,
    required String endId,
    int count = 50,
    double maxDistance = .25,
  }) async {
    constraints.add((count, maxDistance));
    return [musicTrack(startId), musicTrack(endId)];
  }
}

class _RadioMusic extends ExperienceMusic implements MusicAlbumRadioControls {
  MusicDiscoveryBatch? played;
  MediaItem? selected;
  int starts = 0;
  @override
  Future<InstantMixOutcome> playAlbumRadio(
    MediaItem album, {
    double maxDistance = .25,
    MusicDiscoveryBatch? preview,
    MediaItem? startTrack,
  }) async {
    starts++;
    played = preview;
    selected = startTrack;
    return InstantMixOutcome.started;
  }
}

void main() {
  late AppDatabase database;
  late _Profile profile;
  late _Client client;
  late _RadioMusic music;
  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
    database = AppDatabase.forTesting(NativeDatabase.memory());
    profile = _Profile();
    client = _Client();
    music = _RadioMusic();
  });
  tearDown(() {
    profile.dispose();
    music.dispose();
    return database.close();
  });
  MusicRecipe recipe({int count = 25, double distance = .15, String id = 'path'}) => MusicRecipe(
    id: id,
    title: id,
    kind: MusicRecipeKind.adventure,
    seeds: [musicTrack('a'), musicTrack('b')],
    pathTracks: count,
    maxDistance: distance,
  );

  Future<void> pump(WidgetTester tester, {double textScale = 1, MusicRecipe? initialRecipe}) async {
    await tester.runAsync(() => database.customSelect('SELECT 1').get());
    final servers = testMultiServer(clients: [client]);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: database),
          ChangeNotifierProvider<ActiveProfileProvider>.value(value: profile),
          ChangeNotifierProvider<MultiServerProvider>.value(value: servers.provider),
          ChangeNotifierProvider<MusicPlaybackService>.value(value: music),
        ],
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: MusicDiscoveryScreen(
            seed: initialRecipe?.seeds.first ?? musicTrack('a'),
            recipe: initialRecipe ?? recipe(),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
    }
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
  }

  testWidgets('restored controls reach every preview and survive save', (tester) async {
    await pump(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('pathTracks/path/25')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester.widget<DropdownButtonFormField<int>>(find.byKey(const ValueKey('pathTracks/path/25'))).initialValue,
      25,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('maxDistance/path/0.15')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester.widget<DropdownButtonFormField<double>>(find.byKey(const ValueKey('maxDistance/path/0.15'))).initialValue,
      .15,
    );
    await tap(tester, find.text(t.musicExperience.generate));
    expect(client.constraints, [(25, .15)]);
    await tap(tester, find.byKey(const ValueKey('pathTracks/path/25')));
    await tap(tester, find.text('10').last);
    await tap(tester, find.byKey(const ValueKey('maxDistance/path/0.15')));
    await tap(tester, find.text('0.40').last);
    await tap(tester, find.text(t.musicExperience.generate));
    expect(client.constraints, [(25, .15), (10, .4)]);
    await tap(tester, find.text(t.musicExperience.saveRecipe));
    final saved = await tester.runAsync(() => MusicRecipeStore(database, 'p').load());
    expect(saved!.single.pathTracks, 10);
    expect(saved.single.maxDistance, .4);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('selecting a saved recipe resets tuning fields', (tester) async {
    await tester.runAsync(() => MusicRecipeStore(database, 'p').save(recipe(count: 5, distance: .75, id: 'Second')));
    await pump(tester);
    await tap(tester, find.text('Second'));
    expect(find.byKey(const ValueKey('pathTracks/Second/5')), findsOneWidget);
    expect(find.byKey(const ValueKey('maxDistance/Second/0.75')), findsOneWidget);
    await tap(tester, find.text(t.musicExperience.generate));
    expect(client.constraints, [(5, .75)]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('album radio previews whole albums and plays the exact saved batch', (tester) async {
    final seed = musicTrack('album-a').copyWith(kind: MediaKind.album);
    final neighbor = musicTrack('album-b').copyWith(kind: MediaKind.album);
    client.rows = [neighbor];
    client.albums['album-a'] = [musicTrack('a1', album: 'album-a'), musicTrack('a2', album: 'album-a', index: 2)];
    client.albums['album-b'] = [musicTrack('b1', album: 'album-b')];
    final initial = MusicRecipe(id: 'radio', title: 'Whole albums', kind: MusicRecipeKind.mix, seeds: [seed]);
    await pump(tester, initialRecipe: initial);
    await tap(tester, find.text(t.musicTools.albumRadio));
    await tap(tester, find.text(t.musicExperience.generate));
    await tap(tester, find.text(t.musicExperience.play));
    expect(music.starts, 1);
    expect(music.played!.recipe.kind, MusicRecipeKind.albumRadio);
    expect(music.played!.tracks.map((track) => track.id), ['a1', 'a2', 'b1']);
    expect(music.played!.recipe.limit, 500);
    await tap(tester, find.text(t.musicExperience.saveRecipe));
    final saved = (await tester.runAsync(() => MusicRecipeStore(database, 'p').load()))!.single;
    expect(saved.kind, MusicRecipeKind.albumRadio);
    expect(saved.seeds.single.id, 'album-a');
    expect(saved.maxDistance, .25);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('saved album radio controls fit 320px with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final initial = MusicRecipe(
      id: 'radio',
      title: 'Radio',
      kind: MusicRecipeKind.albumRadio,
      seeds: [musicTrack('a').copyWith(kind: MediaKind.album)],
      maxDistance: .4,
    );
    await pump(tester, initialRecipe: initial, textScale: 2);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('maxDistance/radio/0.4')),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(t.musicTools.albumRadio), findsOneWidget);
    expect(find.byKey(const ValueKey('pathTracks/radio/50')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('same profile identity mutation retires the editor and prevents generation', (tester) async {
    await pump(tester);
    profile.retire();
    await tester.pumpAndSettle();
    expect(find.text(t.musicExperience.generate), findsNothing);
    expect(find.text(t.musicExperience.error), findsOneWidget);
    expect(client.constraints, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final phase in ['pending', 'retained']) {
    testWidgets('same-authentication account change retires related results: $phase', (tester) async {
      final pending = Completer<List<MediaItem>>();
      client.sonic = (_) => pending.future;
      await pump(tester);
      await tester.scrollUntilVisible(
        find.text(t.musicExperience.related),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text(t.musicExperience.related));
      await tester.pump();
      if (phase == 'retained') {
        pending.complete([musicTrack('Suggestion')]);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Suggestion'), 100, scrollable: find.byType(Scrollable).first);
        expect(find.text('Suggestion'), findsOneWidget);
      }
      client.scopedServerId = 's/new-account';
      profile.refresh();
      if (phase == 'pending') pending.complete([musicTrack('Suggestion')]);
      await tester.pumpAndSettle();
      expect(find.text('Suggestion'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('sonic controls fit 320px and 200 percent text', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pump(tester, textScale: 2);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('pathTracks/path/25')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('maxDistance/path/0.15')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
