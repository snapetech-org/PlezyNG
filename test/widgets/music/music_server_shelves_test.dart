import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/music/music_experience.dart';
import 'package:plezy/services/music/music_library_store.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/playback_launch_observer.dart';
import 'package:plezy/widgets/music/music_server_shelves.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/music_experience_fakes.dart';
import '../../test_helpers/multi_server_fixtures.dart';

class _Libraries extends ChangeNotifier implements LibrariesProvider {
  @override
  bool get isDisposed => false;
  @override
  int libraryContentEpoch(String key) => 0;
  @override
  List<MediaLibrary> get libraries => const [
    MediaLibrary(
      id: 'library',
      backend: MediaBackend.plex,
      title: 'Music library',
      kind: MediaKind.artist,
      serverId: 's',
    ),
    MediaLibrary(id: 'video', backend: MediaBackend.plex, title: 'Video', kind: MediaKind.movie, serverId: 's'),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Hidden extends ChangeNotifier implements HiddenLibrariesProvider {
  @override
  bool get isDisposed => false;
  @override
  final Set<String> hiddenLibraryKeys = {};
  @override
  Future<void> ensureInitialized() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Profile extends ChangeNotifier implements ActiveProfileProvider {
  @override
  String activeId = 'p';
  @override
  bool isBinding = false;
  @override
  bool lastBindingSucceeded = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Experience extends ChangeNotifier implements MusicExperience {
  _Experience(this.store);
  @override
  final MusicLibraryStore store;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends ExperienceClient {
  bool failed = false, empty = false;
  int reads = 0;
  Future<List<MediaItem>>? album;
  Future<List<MediaHub>>? pending;
  @override
  Future<List<MediaHub>> fetchLibraryHubs(
    String libraryId, {
    required String libraryName,
    int limit = 12,
    bool includePlaybackHubs = true,
    MediaKind? libraryKind,
    HubFetchDiagnostics? diagnostics,
  }) async {
    expect(libraryId, 'library');
    reads++;
    if (failed) throw StateError('unavailable');
    if (empty) return [];
    return pending ??
        [
          MediaHub(
            id: 'native-family',
            title: 'Server picks',
            type: 'track',
            items: [musicTrack('A track')],
            serverId: 's',
          ),
        ];
  }

  @override
  Future<List<MediaItem>> fetchAlbumTracks(String id) async =>
      album ?? [musicTrack('A track'), musicTrack('Next track')];
}

class _Music extends ExperienceMusic {
  List<MediaItem> started = [];
  MusicPlayContext? startedContext;
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
    startedContext = playContext;
  }
}

void main() {
  late AppDatabase database;
  late _Experience experience;
  late _Libraries libraries;
  late _Hidden hidden;
  late _Profile profile;
  late _Client client;
  late _Music music;
  late MultiServerProvider servers;
  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
    database = AppDatabase.forTesting(NativeDatabase.memory());
    experience = _Experience(MusicLibraryStore(database, 'p'));
    libraries = _Libraries();
    hidden = _Hidden();
    profile = _Profile();
    client = _Client();
    music = _Music();
    servers = testMultiServer(clients: [client]).provider;
  });
  tearDown(() async {
    experience.dispose();
    libraries.dispose();
    hidden.dispose();
    profile.dispose();
    music.dispose();
    await database.close();
  });
  Future<void> mount(WidgetTester tester, {bool large = false}) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MusicExperience>.value(value: experience),
          ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
          ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hidden),
          ChangeNotifierProvider<ActiveProfileProvider>.value(value: profile),
          ChangeNotifierProvider<MultiServerProvider>.value(value: servers),
          ChangeNotifierProvider<MusicPlaybackService>.value(value: music),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            builder: (_, child) => MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(large ? 2 : 1)),
              child: child!,
            ),
            home: const Scaffold(body: SingleChildScrollView(child: MusicServerShelves())),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> expand(WidgetTester tester) async {
    await tester.tap(find.text('Server picks'));
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  testWidgets('server previews start the shared album queue with owned rows', (tester) async {
    await mount(tester);
    await expand(tester);
    expect(find.text('Test server · Music library'), findsOneWidget);
    await tester.tap(find.text('A track'));
    await tester.pumpAndSettle();
    expect(music.started.map((row) => row.id), ['A track', 'Next track']);
    expect(music.startedContext?.kind, MusicPlayContextKind.album);
    expect(client.reads, 1);
    await close(tester);
  });
  testWidgets('invalid album expansion falls back only to the authorized recommendation track', (tester) async {
    await mount(tester);
    await expand(tester);
    client.album = Future.value([musicTrack('A track'), musicTrack('Foreign', server: 'elsewhere')]);
    await tester.tap(find.text('A track'));
    await tester.pumpAndSettle();
    expect(music.started.map((row) => row.id), ['A track']);
    expect(music.startedContext?.kind, MusicPlayContextKind.tracks);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('retained row callbacks cannot start music after profile replacement', (tester) async {
    await mount(tester);
    await expand(tester);
    final action = tester.widget<ListTile>(find.widgetWithText(ListTile, 'A track')).onTap!;
    profile.activeId = 'other';
    action();
    await tester.pumpAndSettle();
    expect(music.started, isEmpty);
    await close(tester);
  });
  testWidgets('account retirement during album expansion cannot start a stale queue', (tester) async {
    await mount(tester);
    await expand(tester);
    final album = Completer<List<MediaItem>>();
    client.album = album.future;
    await tester.tap(find.text('A track'));
    await tester.pump();
    client.scopedServerId = 's/another-account';
    album.complete([musicTrack('A track')]);
    await tester.pumpAndSettle();
    expect(music.started, isEmpty);
    await close(tester);
  });
  testWidgets('hiding a library invalidates completed previews and avoids another request', (tester) async {
    await mount(tester);
    hidden.hiddenLibraryKeys.add('s:library');
    hidden.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Server picks'), findsNothing);
    expect(find.text(t.libraries.noRecommendations), findsOneWidget);
    expect(client.reads, 1);
    await close(tester);
  });
  testWidgets('profile binding and a failed PIN result cannot query library shelves', (tester) async {
    profile.isBinding = true;
    await mount(tester);
    expect(client.reads, 0);
    profile.isBinding = false;
    profile.lastBindingSucceeded = false;
    profile.notifyListeners();
    await tester.pumpAndSettle();
    expect(client.reads, 0);
    profile.lastBindingSucceeded = true;
    profile.notifyListeners();
    await tester.pumpAndSettle();
    expect(client.reads, 1);
    expect(find.text('Server picks'), findsOneWidget);
    await close(tester);
  });
  testWidgets('late recommendations are discarded after a visibility change', (tester) async {
    final response = Completer<List<MediaHub>>();
    client.pending = response.future;
    await mount(tester);
    hidden.hiddenLibraryKeys.add('s:library');
    hidden.notifyListeners();
    await tester.pumpAndSettle();
    response.complete([
      MediaHub(id: 'late', title: 'Retired picks', type: 'track', serverId: 's', items: [musicTrack('A track')]),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Retired picks'), findsNothing);
    await close(tester);
  });
  testWidgets('a failed provider does not masquerade as an empty recommendation library', (tester) async {
    client.failed = true;
    await mount(tester);
    expect(find.text(t.musicExperience.error), findsOneWidget);
    expect(find.text(t.libraries.noRecommendations), findsNothing);
    await close(tester);
  });
  testWidgets('server shelves remain usable at 320 pixels with 200 percent text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, large: true);
    await expand(tester);
    expect(find.text('A track'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });
}
