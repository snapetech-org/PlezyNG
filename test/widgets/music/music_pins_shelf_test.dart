import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/services/music/music_experience.dart';
import 'package:plezy/services/music/music_library_store.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/playback_launch_observer.dart';
import 'package:plezy/widgets/music/music_pins_shelf.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/music_experience_fakes.dart';

class _Client extends ExperienceClient {
  Future<MediaItem?> Function(String)? fetch;
  @override
  Future<MediaItem?> fetchItem(String id) async => fetch == null ? musicTrack(id) : await fetch!(id);
}

class _Music extends ExperienceMusic {
  List<MediaItem> started = [];
  @override
  Future<void> playFromList({
    required List<MediaItem> tracks,
    MediaItem? startTrack,
    required MusicPlayContext playContext,
    bool shuffle = false,
    Duration? initialPosition,
    bool offline = false,
    PlaybackLaunchObserver? launchObserver,
  }) async {
    started = tracks;
  }
}

void main() {
  late AppDatabase database;
  late MusicExperience experience;
  late _Music music;
  late _Client client;
  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
    database = AppDatabase.forTesting(NativeDatabase.memory());
    music = _Music();
    client = _Client();
    experience = MusicExperience(music: music, store: MusicLibraryStore(database, 'p'), clientFor: (_) => client);
  });
  tearDown(() async {
    experience.dispose();
    music.dispose();
    await database.close();
  });
  Future<void> pump(WidgetTester tester, {bool editing = false, bool largeText = false}) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<MusicExperience>.value(
        value: experience,
        child: TranslationProvider(
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(largeText ? 2 : 1)),
              child: Scaffold(
                body: SingleChildScrollView(child: MusicPinsShelf(editing: editing)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
  }

  testWidgets('a pinned track starts the existing shared music session with fresh metadata', (tester) async {
    await tester.runAsync(() => experience.pins.save(musicTrack('a')));
    client.fetch = (id) async => musicTrack(id).copyWith(title: 'Authorized title');
    await pump(tester);
    expect(find.text('a'), findsOneWidget);
    await tester.tap(find.text('a'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
    expect(music.started.single.title, 'Authorized title');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('account retirement during open cannot start a stale track', (tester) async {
    await tester.runAsync(() => experience.pins.save(musicTrack('a')));
    await pump(tester);
    final remote = Completer<MediaItem?>();
    client.fetch = (_) => remote.future;
    await tester.tap(find.text('a'));
    await tester.pump();
    client.scopedServerId = 's/another-user';
    remote.complete(musicTrack('a'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
    expect(music.started, isEmpty);
    experience.pins.refresh();
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
    expect(find.text('a'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('editor persists drag ordering and removes the selected pin', (tester) async {
    await tester.runAsync(() => experience.pins.save(musicTrack('a')));
    await tester.runAsync(() => experience.pins.save(musicTrack('b')));
    await pump(tester, editing: true);
    tester.widget<ReorderableListView>(find.byType(ReorderableListView)).onReorderItem!(0, 1);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
    expect((await tester.runAsync(experience.pins.load))!.map((pin) => pin.item.id), ['b', 'a']);
    await tester.tap(find.byTooltip(t.musicTools.unpin).first);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
    expect((await tester.runAsync(experience.pins.load))!.single.item.id, 'a');
    expect(find.text('b'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pins update live after save and fit a narrow screen at large text', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pump(tester, editing: true, largeText: true);
    client.fetch = (id) async => musicTrack(id).copyWith(title: 'An intentionally long album and track title');
    await tester.runAsync(() => experience.pins.save(musicTrack('a')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
    expect(find.text('An intentionally long album and track title'), findsOneWidget);
    expect(find.byTooltip(t.musicTools.unpin), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
