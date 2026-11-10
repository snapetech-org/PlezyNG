import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/music/music_history_screen.dart';
import 'package:plezy/services/music/music_experience.dart';
import 'package:plezy/services/music/music_library_store.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_client.dart';

import '../../test_helpers/backend_client_fixtures.dart';
import '../../test_helpers/music_experience_fakes.dart';

class _HistoryStore extends MusicLibraryStore {
  _HistoryStore(AppDatabase database) : super(database, 'test-profile');

  final changes = StreamController<void>.broadcast();
  final windows = <int>[];
  final olderPage = Completer<MusicHistoryPage>();
  bool hasImport = false;

  static MusicHistoryEntry entry(String id, int seconds) => MusicHistoryEntry(
    id: id,
    item: musicTrack(id),
    startedAt: DateTime.utc(2026, 11, 9, 0, 0, seconds),
    listenedMs: 30000,
    finished: true,
  );

  @override
  Stream<void> get historyChanges => changes.stream;

  @override
  Future<MusicHistoryPage> historyWindow(int pages) async {
    windows.add(pages);
    final recent = entry('recent', 1);
    return MusicHistoryPage([
      if (hasImport) entry('imported', 2),
      recent,
      if (pages > 1) entry('older', 0),
    ], pages == 1 ? recent.cursor : null);
  }

  @override
  Future<MusicHistoryPage> historyPage({int limit = MusicLibraryStore.historyPageSize, (int, String)? before}) =>
      olderPage.future;

  Future<void> close() => changes.close();
}

class _Profile extends ChangeNotifier implements ActiveProfileProvider {
  @override
  String get activeId => 'test-profile';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Servers extends ChangeNotifier implements MultiServerProvider {
  _Servers(this.client);
  final PlexClient client;
  @override
  List<String> get onlineServerIds => [client.serverId.value];
  @override
  PlexClient? getPlexClientForServer(ServerId serverId) => serverId == client.serverId ? client : null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Libraries extends ChangeNotifier implements LibrariesProvider {
  @override
  List<MediaLibrary> get libraries => const [
    MediaLibrary(id: '3', backend: MediaBackend.plex, title: 'My Music', kind: MediaKind.artist, serverId: 'server'),
    MediaLibrary(id: '4', backend: MediaBackend.plex, title: 'Private', kind: MediaKind.artist, serverId: 'server'),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Hidden extends ChangeNotifier implements HiddenLibrariesProvider {
  @override
  Set<String> hiddenLibraryKeys = {'server:4'};

  void hideMusic() {
    hiddenLibraryKeys = {'server:3', 'server:4'};
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

http.Response _serverPage(int offset) => http.Response(
  jsonEncode({
    'MediaContainer': {
      'offset': offset,
      'size': 1,
      'totalSize': 2,
      'Metadata': [
        {
          'historyKey': '/status/sessions/history/${2 - offset}',
          'accountID': 1,
          'ratingKey': '42',
          'type': 'track',
          'librarySectionID': '3',
          'title': 'Repeated server play',
          'viewedAt': 1760000000 - offset,
        },
      ],
    },
  }),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets('live imports coalesce and preserve a page being loaded', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final store = _HistoryStore(database);
    final music = ExperienceMusic();
    final experience = MusicExperience(music: music, store: store, clientFor: (_) => null);
    await tester.pumpWidget(
      ChangeNotifierProvider<MusicExperience>.value(
        value: experience,
        child: const MaterialApp(home: MusicHistoryScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(store.windows, [1]);
    await tester.tap(find.text(t.fileSources.loadMore));
    await tester.pump();
    store.hasImport = true;
    store.changes.add(null);
    store.changes.add(null);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(store.windows, [1]);
    store.olderPage.complete(MusicHistoryPage([_HistoryStore.entry('older', 0)], null));
    await tester.pumpAndSettle();
    expect(store.windows, [1, 2]);
    for (final id in ['imported', 'recent', 'older']) {
      expect(find.byKey(ValueKey(id)), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox());
    experience.dispose();
    music.dispose();
    await store.close();
    await tester.runAsync(database.close);
  });

  testWidgets('owner history pages are separate, and hiding the library retires its rows', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(database);
    final store = _HistoryStore(database);
    final music = ExperienceMusic();
    final requests = <int>[];
    final client =
        testPlexClient(
            serverId: ServerId('server'),
            handler: (request) async {
              final start = int.parse(request.url.queryParameters['X-Plex-Container-Start']!);
              requests.add(start);
              return _serverPage(start);
            },
          )
          ..plexAccountId = 'plex.owner'
          ..plexMusicUserIdentifier = 'owner'
          ..bindMusicHistoryResource(owned: true);
    final experience = MusicExperience(music: music, store: store, clientFor: (_) => client);
    final hidden = _Hidden();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MusicExperience>.value(value: experience),
          ChangeNotifierProvider<ActiveProfileProvider>(create: (_) => _Profile()),
          ChangeNotifierProvider<MultiServerProvider>(create: (_) => _Servers(client)),
          ChangeNotifierProvider<LibrariesProvider>(create: (_) => _Libraries()),
          ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hidden),
        ],
        child: const MaterialApp(home: MusicHistoryScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recent')), findsOneWidget);
    await tester.tap(find.byTooltip(t.musicTools.serverHistory));
    await tester.pumpAndSettle();
    expect(find.textContaining('Private'), findsNothing);
    await tester.tap(find.text('My Music · Server'));
    await tester.pumpAndSettle();
    expect(find.text('Repeated server play'), findsOneWidget);
    await tester.tap(find.text(t.fileSources.loadMore));
    await tester.pumpAndSettle();
    expect(requests, [0, 1]);
    expect(find.text('Repeated server play'), findsNWidgets(2));
    expect(store.windows, [1]);
    hidden.hideMusic();
    await tester.pumpAndSettle();
    expect(find.text('Repeated server play'), findsNothing);
    expect(find.text(t.musicExperience.error), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    experience.dispose();
    hidden.dispose();
    music.dispose();
    client.close();
    await store.close();
    await tester.runAsync(database.close);
  });
}
