import 'package:plezy/services/music/server_music_radio.dart';
import 'package:drift/native.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/music/music_experience.dart';
import 'package:plezy/services/music/music_driving_routes.dart';
import 'package:plezy/services/music/music_library_store.dart';
import 'package:plezy/services/music/music_system_audio_routes.dart';
import 'package:plezy/services/music/music_background_frames.dart';
import 'music_system_audio_routes_test.dart' show route;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/services/music/music_car_host.dart';
import 'package:plezy/services/music/music_discovery.dart';
import 'package:plezy/services/music/music_station.dart';
import 'package:plezy/services/music/music_queue_controller.dart';
import 'package:plezy/services/music/music_queue_items.dart';
import 'package:plezy/services/playback_launch_observer.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import '../../test_helpers/music_experience_fakes.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/screens/music/music_driving_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:provider/provider.dart';
import '../../test_helpers/media_items.dart';
import '../../test_helpers/stub_music_playback_service.dart';
import '../../test_helpers/prefs.dart';

class Profiles extends ChangeNotifier implements ActiveProfileProvider {
  String id = 'one';
  @override
  int identityMutationGeneration = 1;
  @override
  String get activeId => id;
  bool binding = false, succeeded = true;
  @override
  bool get isBinding => binding;
  @override
  bool get lastBindingSucceeded => succeeded;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Experience extends ChangeNotifier implements MusicExperience {
  _Experience(this.drivingRoutes);
  @override
  final MusicDrivingRoutes drivingRoutes;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Music extends StubMusicPlaybackService {
  final tracks = [
    testMediaItem(id: 'a', serverId: 'server', kind: MediaKind.track),
    testMediaItem(id: 'b', serverId: 'server', kind: MediaKind.track),
  ];
  int? jumped;
  int pauses = 0;
  List<MediaItem>? started;
  bool? startedOffline;
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
    startedOffline = offline;
    await super.playFromList(tracks: tracks, playContext: playContext, offline: offline);
  }

  @override
  List<MediaItem> get queue => tracks;
  @override
  int get currentIndex => 0;
  @override
  Future<void> jumpTo(int index) async {
    jumped = index;
  }

  @override
  Future<void> pause() async {
    pauses++;
  }

  void edit() {
    tracks.removeLast();
    notifyListeners();
  }
}

class RadioMusic extends Music implements MusicAlbumRadioControls, MusicStationRadioControls {
  MusicStationBatch? stationRadio;
  @override
  Future<InstantMixOutcome> playStationRadio(
    MusicStationBatch preview, {
    MediaItem? startTrack,
    bool shuffle = false,
  }) async {
    beginPlayIntent();
    if (!preview.isCurrent()) return InstantMixOutcome.superseded;
    stationRadio = preview;
    playing = true;
    return InstantMixOutcome.started;
  }

  MusicDiscoveryBatch? radio;
  bool playing = false;
  @override
  bool get isPlaying => playing;
  @override
  Future<InstantMixOutcome> playAlbumRadio(
    MediaItem album, {
    double maxDistance = .25,
    MusicDiscoveryBatch? preview,
    MediaItem? startTrack,
  }) async {
    beginPlayIntent();
    if (preview == null || !preview.isCurrent()) return InstantMixOutcome.superseded;
    radio = preview;
    playing = true;
    return InstantMixOutcome.started;
  }
}

class WindowMusic extends Music {
  final controller = MusicQueueController();
  @override
  List<MediaItem> get queue => controller.queue;
  @override
  int get currentIndex => controller.cursor;
  void publish() => notifyListeners();
  @override
  void reorder(int from, int to) {
    controller.move(from, to);
    notifyListeners();
  }
}

class CatalogHidden extends ChangeNotifier implements HiddenLibrariesProvider {
  @override
  final String profileId = 'one';
  @override
  bool isDisposed = false, isInitialized = true;
  @override
  Set<String> hiddenLibraryKeys = {};
  @override
  bool isLibraryHidden(String key) => hiddenLibraryKeys.contains(key);
  @override
  Future<void> ensureInitialized() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CatalogLibraries extends ChangeNotifier implements LibrariesProvider {
  @override
  bool get isDisposed => false;
  @override
  final libraries = [
    const MediaLibrary(
      id: 'library',
      title: 'Music',
      backend: MediaBackend.plex,
      kind: MediaKind.artist,
      serverId: 's',
    ),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CatalogClient extends ExperienceClient {
  int reads = 0;
  Future<LibraryPage<MediaItem>> Function(int start, int size)? tracksPage;
  @override
  Future<List<MediaItem>> fetchArtistAlbums(MediaItem artist) async => albums[artist.id] ?? [];
  @override
  Future<LibraryPage<MediaItem>> fetchMusicTracksPage(
    String id, {
    required MediaKind kind,
    String? libraryId,
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    reads++;
    return tracksPage!(start ?? 0, size ?? 200);
  }
}

class MediaBrowserCatalogClient extends CatalogClient {
  MediaBrowserCatalogClient(this.backend);
  @override
  final MediaBackend backend;
  String? trackLibrary;
  @override
  Future<LibraryPage<MediaItem>> fetchMusicTracksPage(
    String id, {
    required MediaKind kind,
    String? libraryId,
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    trackLibrary = libraryId;
    final page = await super.fetchMusicTracksPage(
      id,
      kind: kind,
      libraryId: libraryId,
      start: start,
      size: size,
      abort: abort,
    );
    return LibraryPage(
      items: [
        for (final item in page.items)
          item.libraryId == null && libraryId != null ? item.copyWith(libraryId: libraryId) : item,
      ],
      totalCount: page.totalCount,
      offset: page.offset,
    );
  }
}

const nativeRadio = ServerMusicRadio(
  serverId: 's',
  libraryId: 'library',
  key: '/library/metadata/1/station/radio?type=10',
  title: 'Native Radio',
);

class ServerRadioClient extends CatalogClient implements ServerMusicRadioClient {
  List<ServerMusicRadio> radioRows = [nativeRadio];
  Future<List<ServerMusicRadio>>? pendingRadios;
  Future<List<MediaItem>>? pendingTracks;
  int radioReads = 0;
  @override
  Future<List<ServerMusicRadio>> serverMusicRadios(String libraryId) async {
    expect(libraryId, 'library');
    return pendingRadios ?? radioRows;
  }

  @override
  bool serverMusicRadioCurrent(ServerMusicRadio radio) => radioRows.any((row) => identical(row, radio));
  @override
  Future<List<MediaItem>> serverMusicRadioTracks(ServerMusicRadio radio, {int limit = 100}) async {
    radioReads++;
    return pendingTracks ?? [musicTrack('radio-one')];
  }
}

class ServerRadioMusic extends RadioMusic implements MusicServerRadioControls {
  ServerMusicRadio? serverRadio;
  bool radioShuffle = false;
  MusicRepeatMode? requestedRepeat;
  @override
  void setRepeatMode(MusicRepeatMode mode) {
    requestedRepeat = mode;
    super.setRepeatMode(mode);
  }

  List<MediaItem> enqueued = [];
  @override
  void addNext(List<MediaItem> tracks) {
    enqueued = tracks;
    super.addNext(tracks);
  }

  @override
  Future<InstantMixOutcome> playServerRadio(ServerMusicRadio radio, {bool shuffle = false}) async {
    beginPlayIntent();
    serverRadio = radio;
    radioShuffle = shuffle;
    playing = true;
    return InstantMixOutcome.started;
  }
}

class CatalogDownloads extends ChangeNotifier implements DownloadProvider {
  List<MediaItem> tracks = [];
  @override
  String get activeProfileId => 'one';
  @override
  bool get isDisposed => false;
  @override
  bool isDownloaded(String key) => tracks.any((item) => item.globalKey == key);
  String? artworkPath;
  @override
  String? getArtworkLocalPath(ServerId serverId, String? artworkPath) => this.artworkPath;

  @override
  List<MediaItem> get downloadedTracks => tracks;
  void publish(List<MediaItem> value) {
    tracks = value;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const codec = StandardMethodCodec();
  const channel = MethodChannel('com.pleazyng/music_car');
  Future<dynamic> native(String method, [Object? arguments]) async {
    final result = Completer<dynamic>();
    unawaited(
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(MethodCall(method, arguments)),
        (reply) {
          try {
            result.complete(codec.decodeEnvelope(reply!));
          } catch (e) {
            result.completeError(e);
          }
        },
      ),
    );
    return result.future;
  }

  Future<void> mount(
    WidgetTester tester,
    Music music,
    Profiles profiles, {
    CatalogDownloads? downloads,
    AppDatabase? database,
    MultiServerProvider? servers,
    CatalogHidden? hidden,
    CatalogLibraries? libraries,
    MusicDrivingRoutes? drivingRoutes,
    void Function(MethodCall)? onNative,
  }) async {
    final navigator = GlobalKey<NavigatorState>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      onNative?.call(call);
      return null;
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MusicPlaybackService>.value(value: music),
          ChangeNotifierProvider<ActiveProfileProvider>.value(value: profiles),
          if (downloads != null) ChangeNotifierProvider<DownloadProvider>.value(value: downloads),
          if (database != null) Provider<AppDatabase>.value(value: database),
          if (servers != null) ChangeNotifierProvider<MultiServerProvider>.value(value: servers),
          if (hidden != null) ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hidden),
          if (libraries != null) ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
          if (drivingRoutes != null) ChangeNotifierProvider<MusicExperience>(create: (_) => _Experience(drivingRoutes)),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          home: MusicCarHost(navigatorKey: navigator, child: const SizedBox()),
        ),
      ),
    );
    await tester.pump();
  }

  for (final retirement in ['none', 'account', 'profile', 'hidden', 'removed', 'forged']) {
    testWidgets('native server radio has opaque rows and scoped shared playback ($retirement)', (tester) async {
      final music = ServerRadioMusic(), profiles = Profiles(), hidden = CatalogHidden(), libraries = CatalogLibraries();
      final client = ServerRadioClient();
      final servers = testMultiServer(clients: [client]);
      await mount(tester, music, profiles, servers: servers.provider, hidden: hidden, libraries: libraries);
      final root = await native('browse', {'id': 'root'}) as List;
      expect(root.where((row) => row['id'] == 'serverRadio'), hasLength(1));
      final folders = await native('browse', {'id': 'serverRadio'}) as List;
      expect(folders.single['id'], 'radioLibrary:s:library');
      final rows = await native('browse', {'id': folders.single['id']}) as List;
      expect(rows.single['title'], 'Native Radio');
      expect(jsonEncode(rows), isNot(contains(nativeRadio.key)));
      expect(jsonEncode(rows), isNot(contains(client.scopedServerId)));
      final id = rows.single['id'] as String;
      if (retirement == 'account') client.scopedServerId = 's/other';
      if (retirement == 'profile') profiles.identityMutationGeneration++;
      if (retirement == 'hidden') hidden.hiddenLibraryKeys.add('s:library');
      if (retirement == 'removed') client.radioRows = [];
      if (retirement == 'none') {
        expect(await native('playItem', {'id': id}), isTrue);
        expect(identical(music.serverRadio, nativeRadio), isTrue);
      } else {
        await expectLater(
          native('playItem', {'id': retirement == 'forged' ? 'serverRadio:forged' : id}),
          throwsA(isA<PlatformException>()),
        );
        expect(music.serverRadio, isNull);
      }
      expect(music.started, isNull);
      await tester.pumpWidget(const SizedBox());
      music.dispose();
      profiles.dispose();
      hidden.dispose();
      libraries.dispose();
    });
  }

  for (final retirement in ['account', 'profile', 'hidden']) {
    testWidgets('native late radio catalogs retire on $retirement', (tester) async {
      final music = ServerRadioMusic(), profiles = Profiles(), hidden = CatalogHidden(), libraries = CatalogLibraries();
      final client = ServerRadioClient();
      final servers = testMultiServer(clients: [client]);
      await mount(tester, music, profiles, servers: servers.provider, hidden: hidden, libraries: libraries);
      await tester.runAsync(() async {
        final reply = Completer<List<ServerMusicRadio>>();
        client.pendingRadios = reply.future;
        final pending = native('browse', {'id': 'radioLibrary:s:library'});
        await pumpEventQueue();
        if (retirement == 'account') client.authenticationSessionId = Object();
        if (retirement == 'profile') profiles.identityMutationGeneration++;
        if (retirement == 'hidden') hidden.hiddenLibraryKeys.add('s:library');
        reply.complete([nativeRadio]);
        expect(await pending, isEmpty);
      });
      await tester.pumpWidget(const SizedBox());
      music.dispose();
      profiles.dispose();
      hidden.dispose();
      libraries.dispose();
    });
  }

  for (final retirement in ['none', 'intent', 'foreign']) {
    testWidgets('native server radio enqueue remains finite and source-guarded ($retirement)', (tester) async {
      final music = ServerRadioMusic(), profiles = Profiles(), hidden = CatalogHidden(), libraries = CatalogLibraries();
      final client = ServerRadioClient();
      final servers = testMultiServer(clients: [client]);
      await mount(tester, music, profiles, servers: servers.provider, hidden: hidden, libraries: libraries);
      final rows = await native('browse', {'id': 'radioLibrary:s:library'}) as List;
      await tester.runAsync(() async {
        final reply = Completer<List<MediaItem>>();
        client.pendingTracks = reply.future;
        final pending = native('playItem', {'id': rows.single['id'], 'queue': 'next'});
        final check = retirement == 'foreign' ? expectLater(pending, throwsA(isA<PlatformException>())) : null;
        await pumpEventQueue();
        if (retirement == 'intent') music.beginPlayIntent();
        reply.complete([musicTrack('radio-one', server: retirement == 'foreign' ? 'foreign' : 's')]);
        if (check != null) {
          await check;
        } else {
          expect(await pending, retirement == 'none');
        }
      });
      expect(music.enqueued.map((track) => track.id), retirement == 'none' ? ['radio-one'] : isEmpty);
      expect(music.serverRadio, isNull);
      expect(client.radioReads, 1);
      await tester.pumpWidget(const SizedBox());
      music.dispose();
      profiles.dispose();
      hidden.dispose();
      libraries.dispose();
    });
  }

  testWidgets('voice can resolve server radio without exposing its key', (tester) async {
    final music = ServerRadioMusic(), profiles = Profiles(), hidden = CatalogHidden(), libraries = CatalogLibraries();
    final downloads = CatalogDownloads();
    final client = ServerRadioClient();
    final servers = testMultiServer(clients: [client]);
    late AppDatabase database;
    await tester.runAsync(() async {
      database = AppDatabase.forTesting(NativeDatabase.memory());
    });
    await mount(
      tester,
      music,
      profiles,
      servers: servers.provider,
      hidden: hidden,
      libraries: libraries,
      database: database,
      downloads: downloads,
    );
    await tester.runAsync(() async {
      final rows = await native('resolveVoice', {'query': 'Native Radio', 'kind': 'station'}) as List;
      expect(rows.single['kind'], 'station');
      expect(jsonEncode(rows), isNot(contains(nativeRadio.key)));
      expect(await native('playItem', {'id': rows.single['id'], 'shuffle': true, 'repeat': 'all'}), isTrue);
      expect(music.serverRadio?.title, 'Native Radio');
      expect(music.radioShuffle, isTrue);
      expect(music.requestedRepeat, MusicRepeatMode.all);
    });
    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    music.dispose();
    profiles.dispose();
    hidden.dispose();
    libraries.dispose();
    await tester.runAsync(database.close);
  });

  for (final source in ['matching', 'server', 'library']) {
    testWidgets('offline native continuous station remains finite and source-qualified ($source)', (tester) async {
      final music = Music(), profiles = Profiles(), hidden = CatalogHidden(), downloads = CatalogDownloads();
      final servers = testMultiServer();
      final owned = musicTrack(
        'owned',
        server: source == 'server' ? 'other' : 's',
      ).copyWith(libraryId: source == 'library' ? 'other' : 'library');
      downloads.tracks = [owned];
      late AppDatabase database;
      await tester.runAsync(() async {
        database = AppDatabase.forTesting(NativeDatabase.memory());
        final store = MusicLibraryStore(database, 'one');
        final rule = MusicStation(
          id: 'radio',
          title: 'Offline station',
          serverId: 's',
          libraryId: 'library',
          continuous: true,
        );
        await store.saveDocument('station', rule.id, rule.toJson());
        await store.completeStationSnapshot(rule.id, {
          'version': 1,
          'id': rule.id,
          'tracks': [owned.toJson()],
        });
      });
      await mount(
        tester,
        music,
        profiles,
        database: database,
        servers: servers.provider,
        hidden: hidden,
        downloads: downloads,
      );
      await tester.runAsync(() => native('playItem', {'id': 'station:radio'}));
      if (source == 'matching') {
        expect(music.started?.map((track) => track.id), ['owned']);
        expect(music.startedOffline, isTrue);
      } else {
        expect(music.started, isNull);
      }
      await tester.pumpWidget(const SizedBox());
      music.dispose();
      profiles.dispose();
      hidden.dispose();
      downloads.dispose();
      await tester.runAsync(database.close);
    });
  }

  for (final retirement in ['none', 'profile', 'account', 'hidden', 'intent', 'shuffle']) {
    testWidgets('native saved rule radio keeps its original scope ($retirement)', (tester) async {
      final music = RadioMusic(), profiles = Profiles(), hidden = CatalogHidden();
      final client = ExperienceClient();
      final servers = testMultiServer(clients: [client]);
      final album = musicTrack('a').copyWith(kind: MediaKind.album);
      client.albums['a'] = [musicTrack('a1', album: 'a'), musicTrack('a2', album: 'a', index: 2)];
      client.page = (_) async {
        switch (retirement) {
          case 'account':
            client.scopedServerId = 's/other';
          case 'profile':
            profiles.identityMutationGeneration++;
          case 'hidden':
            hidden.hiddenLibraryKeys = {'s:library'};
          case 'intent':
            music.beginPlayIntent();
        }
        return LibraryPage(items: [album], totalCount: 1);
      };
      late AppDatabase database;
      await tester.runAsync(() async {
        database = AppDatabase.forTesting(NativeDatabase.memory());
        final rule = MusicStation(
          id: 'radio',
          title: 'Filtered albums',
          serverId: 's',
          libraryId: 'library',
          continuous: true,
          albums: true,
          trackLimit: 2,
        );
        await MusicLibraryStore(database, 'one').saveDocument('station', rule.id, rule.toJson());
      });
      await mount(tester, music, profiles, database: database, servers: servers.provider, hidden: hidden);
      await tester.runAsync(() async {
        final play = native('playItem', {'id': 'station:radio', if (retirement == 'shuffle') 'shuffle': true});
        if (retirement == 'none') {
          expect(await play, isTrue);
        } else {
          await expectLater(play, throwsA(isA<PlatformException>()));
        }
      });
      if (retirement == 'none') {
        expect(music.stationRadio?.station.continuous, isTrue);
        expect(music.stationRadio?.tracks.map((track) => track.id), ['a1', 'a2']);
      } else {
        expect(music.stationRadio, isNull);
      }
      expect(music.started, isNull);
      await tester.pumpWidget(const SizedBox());
      music.dispose();
      profiles.dispose();
      hidden.dispose();
      await tester.runAsync(database.close);
    });
  }

  for (final retirement in ['none', 'account', 'profile', 'hidden', 'intent', 'shuffle']) {
    testWidgets('saved native album radio retains whole albums and original actor ($retirement)', (tester) async {
      final music = RadioMusic(), profiles = Profiles(), hidden = CatalogHidden();
      final client = ExperienceClient();
      final servers = testMultiServer(clients: [client]);
      final album = musicTrack('a').copyWith(kind: MediaKind.album);
      client.albums['a'] = [musicTrack('a1', album: 'a'), musicTrack('a2', album: 'a', index: 2)];
      client.sonic = (_) async {
        switch (retirement) {
          case 'account':
            client.scopedServerId = 's/other';
          case 'profile':
            profiles.identityMutationGeneration++;
          case 'hidden':
            hidden.hiddenLibraryKeys = {'s:library'};
          case 'intent':
            music.beginPlayIntent();
        }
        return [];
      };
      late AppDatabase database;
      await tester.runAsync(() async {
        database = AppDatabase.forTesting(NativeDatabase.memory());
        await MusicRecipeStore(database, 'one').save(
          MusicRecipe(
            id: 'radio',
            title: 'Whole albums',
            kind: MusicRecipeKind.albumRadio,
            seeds: [album],
            limit: 500,
            maxDistance: .4,
          ),
        );
      });
      await mount(tester, music, profiles, database: database, servers: servers.provider, hidden: hidden);
      final rows = (await tester.runAsync(() => native('browse', {'id': 'recipes'}))) as List;
      expect((rows.single as Map)['id'], 'recipe:radio');
      await tester.runAsync(() async {
        final play = native('playItem', {'id': 'recipe:radio', if (retirement == 'shuffle') 'shuffle': true});
        if (retirement == 'none') {
          expect(await play, isTrue);
        } else {
          await expectLater(play, throwsA(isA<PlatformException>()));
        }
      });
      if (retirement == 'none') {
        expect(music.radio?.recipe.kind, MusicRecipeKind.albumRadio);
        expect(music.radio?.recipe.maxDistance, .4);
        expect(music.radio?.tracks.map((track) => track.id), ['a1', 'a2']);
      } else {
        expect(music.radio, isNull);
      }
      expect(music.started, isNull);
      await tester.pumpWidget(const SizedBox());
      music.dispose();
      profiles.dispose();
      hidden.dispose();
      await tester.runAsync(database.close);
    });
  }

  for (final revokeDownload in [false, true]) {
    testWidgets('opaque artwork retires on download removal=$revokeDownload and queue changes', (tester) async {
      final directory = (await tester.runAsync(() => Directory.systemTemp.createTemp('pleazyng-car-artwork-')))!;
      addTearDown(() => directory.delete(recursive: true));
      final image = File('${directory.path}/art.png');
      final bytes = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(
          recorder,
        ).drawRect(const ui.Rect.fromLTWH(0, 0, 2, 2), ui.Paint()..color = const ui.Color(0xff00ff00));
        final picture = recorder.endRecording();
        final decoded = await picture.toImage(2, 2);
        final data = await decoded.toByteData(format: ui.ImageByteFormat.png);
        decoded.dispose();
        picture.dispose();
        return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      });
      await tester.runAsync(() => image.writeAsBytes(bytes!));
      final music = Music();
      music.tracks[0] = testMediaItem(
        id: 'a',
        serverId: 'server',
        kind: MediaKind.track,
        thumbPath: '/private/artwork',
      );
      final downloads = CatalogDownloads()
        ..tracks = [music.tracks.first]
        ..artworkPath = image.path;
      await mount(tester, music, Profiles(), downloads: downloads);
      final rows = await native('browse', {'id': 'queue'}) as List;
      final row = rows.first as Map;
      expect(row['artwork'], isTrue);
      expect(jsonEncode(rows), isNot(contains('/private/artwork')));
      expect(jsonEncode(rows), isNot(contains(image.path)));
      final result = await tester.runAsync(() async => await native('artwork', {'id': row['id'], 'size': 96}));
      expect(result, isA<Uint8List>());
      expect((result as Uint8List).length, lessThan(512 * 1024));
      if (revokeDownload) {
        downloads.publish([]);
      } else {
        music.edit();
      }
      await tester.pump();
      expect(await native('artwork', {'id': row['id'], 'size': 96}), isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('native artwork rejects arbitrary paths missing rows and unsupported sizes', (tester) async {
    await mount(tester, Music(), Profiles());
    for (final args in [
      {'id': 'https://server.invalid/secret', 'size': 96},
      {'id': '../private', 'size': 96},
      {'id': 'queue:1:0', 'size': 10000},
      {'id': 'queue:1:0', 'size': 96.0},
    ]) {
      expect(await native('artwork', args), isNull);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('widget transport is bound to the exact profile scope and queue revision', (tester) async {
    final calls = <MethodCall>[];
    final music = Music(), profiles = Profiles();
    await mount(tester, music, profiles, onNative: calls.add);
    final snapshot = Map<String, dynamic>.from(calls.lastWhere((call) => call.method == 'snapshot').arguments as Map);
    expect((snapshot['labels'] as Map)['pause'], isNotEmpty);
    await native('transport', {'scope': snapshot['scope'], 'revision': snapshot['revision'], 'command': 'pause'});
    expect(music.pauses, 1);
    await expectLater(
      native('transport', {'scope': 'another-profile', 'revision': snapshot['revision'], 'command': 'pause'}),
      throwsA(isA<PlatformException>()),
    );
    music.edit();
    await tester.pump();
    await expectLater(
      native('transport', {'scope': snapshot['scope'], 'revision': snapshot['revision'], 'command': 'pause'}),
      throwsA(isA<PlatformException>()),
    );
    profiles.id = 'other';
    final latest = Map<String, dynamic>.from(calls.lastWhere((call) => call.method == 'snapshot').arguments as Map);
    await expectLater(
      native('transport', {'scope': latest['scope'], 'revision': latest['revision'], 'command': 'pause'}),
      throwsA(isA<PlatformException>()),
    );
    expect(music.pauses, 1);
  });

  testWidgets('projection enters driving by default, respects opt-out and never starts audio', (tester) async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    final settings = await SettingsService.getInstance();
    final music = Music(), profiles = Profiles();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await mount(tester, music, profiles);
    await native('connection', {'connected': true});
    await tester.pumpAndSettle();
    expect(find.byType(MusicDrivingScreen), findsOneWidget);
    expect(music.jumped, isNull);
    await native('connection', {'connected': false});
    await tester.pumpAndSettle();
    expect(find.byType(MusicDrivingScreen), findsNothing);
    expect(music.pauses, 1);
    await settings.write(SettingsService.musicAutoDriving, false);
    await native('connection', {'connected': true});
    await tester.pumpAndSettle();
    expect(find.byType(MusicDrivingScreen), findsNothing);
    expect(music.jumped, isNull);
    await tester.pumpWidget(const SizedBox());
    music.dispose();
    profiles.dispose();
  });

  testWidgets('immutable queue status retains native references and duplicate reorder retires them', (tester) async {
    final calls = <MethodCall>[];
    final music = WindowMusic(), profiles = Profiles();
    final repeated = testMediaItem(id: 'duplicate', serverId: 'server', kind: MediaKind.track);
    music.controller.load(List.filled(10000, repeated));
    await mount(tester, music, profiles, onNative: calls.add);
    Map snapshot() => calls.lastWhere((call) => call.method == 'snapshot').arguments as Map;
    final original = Map.of(snapshot());
    final rows = await native('browse', {'id': 'queue'}) as List;
    final reference = (rows.first as Map)['id'];
    music.publish();
    await tester.pump();
    expect(snapshot()['revision'], original['revision']);
    music.reorder(0, 1);
    await tester.pump();
    expect(snapshot()['revision'], isNot(original['revision']));
    await expectLater(native('playItem', {'id': reference}), throwsA(isA<PlatformException>()));
    expect(music.jumped, isNull);
    await tester.pumpWidget(const SizedBox());
    music.dispose();
    profiles.dispose();
  });

  for (final retirement in ['none', 'account', 'authentication', 'profile', 'hidden', 'intent']) {
    testWidgets('native artist admission retains its original source ($retirement)', (tester) async {
      final music = Music(), profiles = Profiles(), downloads = CatalogDownloads();
      final client = CatalogClient(), hidden = CatalogHidden(), libraries = CatalogLibraries();
      final servers = testMultiServer(clients: [client]);
      final artist = musicTrack('artist').copyWith(kind: MediaKind.artist);
      client.page = (_) async => LibraryPage(items: [artist], totalCount: 1);
      client.tracksPage = (start, size) async {
        switch (retirement) {
          case 'account':
            client.scopedServerId = 's/other';
          case 'authentication':
            client.authenticationSessionId = Object();
          case 'profile':
            profiles.identityMutationGeneration++;
          case 'hidden':
            hidden.hiddenLibraryKeys = {'s:library'};
          case 'intent':
            music.beginPlayIntent();
        }
        return LibraryPage(
          items: List.generate(size, (index) => musicTrack('t$start-$index')),
          totalCount: 10000,
          offset: start,
        );
      };
      await mount(
        tester,
        music,
        profiles,
        downloads: downloads,
        servers: servers.provider,
        hidden: hidden,
        libraries: libraries,
      );
      final rows = await native('browse', {'id': 'library:s:library'}) as List;
      final play = native('playItem', {'id': (rows.single as Map)['id']});
      if (retirement == 'none') {
        await play;
        expect(music.started, isA<MusicQueueItemsSnapshot>());
        expect(music.started?.length, 10000);
        expect(client.reads, 50);
      } else {
        await expectLater(play, throwsA(isA<PlatformException>()));
        expect(music.started, isNull);
        expect(client.reads, 1);
      }
      await tester.pumpWidget(const SizedBox());
      music.dispose();
      profiles.dispose();
      downloads.dispose();
      hidden.dispose();
      libraries.dispose();
    });
  }

  testWidgets('native artist pages reject foreign identities and keep the raw pagination cursor', (tester) async {
    final music = Music(), profiles = Profiles(), client = CatalogClient();
    final hidden = CatalogHidden(), libraries = CatalogLibraries();
    final servers = testMultiServer(clients: [client]);
    final artist = musicTrack('artist').copyWith(kind: MediaKind.artist);
    client.page = (_) async => LibraryPage(
      items: [
        artist,
        artist.copyWith(id: 'foreign-server', serverId: 'other'),
        artist.copyWith(id: 'foreign-library', libraryId: 'other'),
        MediaItem.fromJson({...artist.toJson(), 'id': 'unqualified', 'libraryId': null}),
        MediaItem.fromJson({...artist.toJson(), 'id': 'foreign-backend', 'backend': 'jellyfin'}),
        artist.copyWith(id: 'wrong-kind', kind: MediaKind.movie),
        artist.copyWith(id: ''),
      ],
      totalCount: 1000,
    );
    await mount(tester, music, profiles, servers: servers.provider, hidden: hidden, libraries: libraries);
    final rows = await native('browse', {'id': 'library:s:library'}) as List;
    expect(rows, hasLength(2));
    expect(rows.first['title'], artist.displayTitle);
    expect(rows.last['id'], startsWith('page:7:'));
    await tester.pumpWidget(const SizedBox());
    music.dispose();
    profiles.dispose();
    hidden.dispose();
    libraries.dispose();
  });

  testWidgets('native artist pagination rejects a mismatched server offset', (tester) async {
    final music = Music(), profiles = Profiles(), client = CatalogClient();
    final hidden = CatalogHidden(), libraries = CatalogLibraries();
    final servers = testMultiServer(clients: [client]);
    client.page = (_) async =>
        LibraryPage(items: [musicTrack('artist').copyWith(kind: MediaKind.artist)], offset: 2, totalCount: 3);
    await mount(tester, music, profiles, servers: servers.provider, hidden: hidden, libraries: libraries);
    await expectLater(native('browse', {'id': 'library:s:library'}), throwsA(isA<PlatformException>()));
    await tester.pumpWidget(const SizedBox());
    music.dispose();
    profiles.dispose();
    hidden.dispose();
    libraries.dispose();
  });

  testWidgets('native artist pages retire when their library disappears during the read', (tester) async {
    final music = Music(), profiles = Profiles(), client = CatalogClient();
    final hidden = CatalogHidden(), libraries = CatalogLibraries();
    final servers = testMultiServer(clients: [client]);
    client.page = (_) async {
      libraries.libraries.clear();
      return LibraryPage(items: [musicTrack('artist').copyWith(kind: MediaKind.artist)], totalCount: 1);
    };
    await mount(tester, music, profiles, servers: servers.provider, hidden: hidden, libraries: libraries);
    expect(await native('browse', {'id': 'library:s:library'}), isEmpty);
    await tester.pumpWidget(const SizedBox());
    music.dispose();
    profiles.dispose();
    hidden.dispose();
    libraries.dispose();
  });

  testWidgets('native descendants retain the original library, backend, kind and album parent', (tester) async {
    final music = Music(), profiles = Profiles(), client = CatalogClient();
    final hidden = CatalogHidden(), libraries = CatalogLibraries();
    final servers = testMultiServer(clients: [client]);
    client.rows = [musicTrack('artist').copyWith(kind: MediaKind.artist)];
    final album = musicTrack('album').copyWith(kind: MediaKind.album);
    client.albums['artist'] = [
      album,
      album.copyWith(id: 'foreign-album', libraryId: 'other'),
      album.copyWith(id: 'wrong-kind', kind: MediaKind.movie),
    ];
    final track = musicTrack('track', album: 'album');
    client.tracksPage = (_, _) async => LibraryPage(
      items: [
        track,
        track.copyWith(id: 'foreign-track', libraryId: 'other'),
        MediaItem.fromJson({...track.toJson(), 'id': 'foreign-backend', 'backend': 'jellyfin'}),
        track.copyWith(id: 'wrong-album', parentId: 'other'),
      ],
      totalCount: 4,
    );
    await mount(tester, music, profiles, servers: servers.provider, hidden: hidden, libraries: libraries);
    final artists = await native('browse', {'id': 'library:s:library'}) as List;
    final albums = await native('browse', {'id': artists.single['id']}) as List;
    expect(albums, hasLength(1));
    expect(albums.single['title'], album.displayTitle);
    final tracks = await native('browse', {'id': albums.single['id']}) as List;
    expect(tracks, hasLength(1));
    expect(tracks.single['title'], track.displayTitle);
    await tester.pumpWidget(const SizedBox());
    music.dispose();
    profiles.dispose();
    hidden.dispose();
    libraries.dispose();
  });

  for (final backend in [MediaBackend.jellyfin, MediaBackend.emby]) {
    testWidgets('native $backend browsing retains scoped artist and album context', (tester) async {
      final music = Music(), profiles = Profiles(), client = MediaBrowserCatalogClient(backend);
      final hidden = CatalogHidden(), libraries = CatalogLibraries();
      libraries.libraries
        ..clear()
        ..add(MediaLibrary(id: 'library', title: 'Music', backend: backend, kind: MediaKind.artist, serverId: 's'));
      final servers = testMultiServer(clients: [client]);
      MediaItem row(String id, MediaKind kind, {String? library, String? parent}) => MediaItem.fromJson({
        ...musicTrack(id).toJson(),
        'backend': backend.id,
        'kind': kind.name,
        'libraryId': library,
        'parentId': parent,
      });
      client.rows = [row('artist', MediaKind.artist)];
      // The artist-album client retains its explicit ParentId library request.
      client.albums['artist'] = [row('album', MediaKind.album, library: 'library')];
      client.tracksPage = (_, _) async => LibraryPage(
        items: [
          row('track', MediaKind.track, parent: 'album'),
          row('wrong-album', MediaKind.track, parent: 'other'),
          row('foreign-track', MediaKind.track, parent: 'album', library: 'other'),
        ],
        totalCount: 3,
      );
      await mount(tester, music, profiles, servers: servers.provider, hidden: hidden, libraries: libraries);
      final artists = await native('browse', {'id': 'library:s:library'}) as List;
      expect(artists, hasLength(1));
      final albums = await native('browse', {'id': artists.single['id']}) as List;
      expect(albums, hasLength(1));
      final tracks = await native('browse', {'id': albums.single['id']}) as List;
      expect(tracks, hasLength(1));
      expect(tracks.single['title'], 'track');
      expect(client.trackLibrary, 'library');
      client.tracksPage = (_, _) async =>
          LibraryPage(items: [row('track', MediaKind.track, parent: 'album')], totalCount: 1);
      await native('playItem', {'id': albums.single['id']});
      expect(music.started?.single.id, 'track');
      expect(music.started?.single.libraryId, 'library');
      libraries.libraries.clear();
      expect(await native('browse', {'id': albums.single['id']}), isEmpty);
      expect(await native('playItem', {'id': albums.single['id']}), isFalse);
      await tester.pumpWidget(const SizedBox());
      music.dispose();
      profiles.dispose();
      hidden.dispose();
      libraries.dispose();
    });
  }

  testWidgets('account replacement during native browse cannot rebind old rows to the new account', (tester) async {
    final music = Music(), profiles = Profiles(), downloads = CatalogDownloads();
    final client = CatalogClient(), hidden = CatalogHidden(), libraries = CatalogLibraries();
    final servers = testMultiServer(clients: [client]);
    client.page = (_) async {
      client.scopedServerId = 's/other';
      return LibraryPage(items: [musicTrack('artist').copyWith(kind: MediaKind.artist)], totalCount: 1);
    };
    await mount(
      tester,
      music,
      profiles,
      downloads: downloads,
      servers: servers.provider,
      hidden: hidden,
      libraries: libraries,
    );
    expect(await native('browse', {'id': 'library:s:library'}), isEmpty);
    expect(music.started, isNull);
    await tester.pumpWidget(const SizedBox());
    music.dispose();
    profiles.dispose();
    downloads.dispose();
    hidden.dispose();
    libraries.dispose();
  });

  testWidgets('an account change after native browse cannot reuse the old item', (tester) async {
    final music = Music(), profiles = Profiles(), downloads = CatalogDownloads(), client = CatalogClient();
    final servers = testMultiServer(clients: [client]);
    downloads.tracks = [musicTrack('owned')];
    await mount(tester, music, profiles, downloads: downloads, servers: servers.provider);
    final rows = await native('browse', {'id': 'offline'}) as List;
    client.scopedServerId = 's/other';
    expect(await native('playItem', {'id': (rows.single as Map)['id']}), isFalse);
    expect(music.started, isNull);
    await tester.pumpWidget(const SizedBox());
    music.dispose();
    profiles.dispose();
    downloads.dispose();
  });

  testWidgets('native queue rows contain no URLs and reject edits that changed their indices', (tester) async {
    final music = Music(), profiles = Profiles();
    await mount(tester, music, profiles);
    final rows = await native('browse', {'id': 'queue'}) as List;
    final id = (rows.last as Map)['id'];
    expect(id, startsWith('queue:'));
    expect((rows.first as Map).keys, isNot(contains('url')));
    music.edit();
    await tester.pump();
    await expectLater(native('playItem', {'id': id}), throwsA(isA<PlatformException>()));
    expect(music.jumped, isNull);
  });
  testWidgets('profile replacement invalidates native requests and attachment never starts audio', (tester) async {
    final music = Music(), profiles = Profiles();
    await mount(tester, music, profiles);
    await native('connection', {'connected': true});
    expect(music.jumped, isNull);
    await native('connection', {'connected': false});
    expect(music.pauses, 1);
    profiles.id = 'two';
    await expectLater(native('browse', {'id': 'queue'}), throwsA(isA<PlatformException>()));
  });
  testWidgets('unmount clears native catalog even after the active profile changed', (tester) async {
    final music = Music(), profiles = Profiles();
    await mount(tester, music, profiles);
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    profiles.id = 'two';
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(calls, contains('close'));
  });
  testWidgets('large queues remain browsable through bounded native pages', (tester) async {
    final music = Music(), profiles = Profiles();
    music.tracks.addAll(
      List.generate(205, (i) => testMediaItem(id: 'extra$i', serverId: 'server', kind: MediaKind.track)),
    );
    await mount(tester, music, profiles);
    var rows = await native('browse', {'id': 'queue'}) as List;
    final seen = <String>[];
    while (true) {
      expect(rows.length, lessThanOrEqualTo(100));
      seen.addAll(rows.where((row) => (row as Map)['playable'] == true).map((row) => row['id'] as String));
      final more = rows.where((row) => (row as Map)['playable'] == false).toList();
      if (more.isEmpty) break;
      rows = await native('browse', {'id': more.single['id']}) as List;
    }
    expect(seen.toSet(), hasLength(207));
    expect(seen, hasLength(207));
  });
  testWidgets('native catalogs refresh for membership changes, not download progress', (tester) async {
    final music = Music(), profiles = Profiles(), downloads = CatalogDownloads();
    await mount(tester, music, profiles, downloads: downloads);
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    downloads.publish(music.tracks);
    await tester.pump();
    expect(calls.where((call) => call == 'catalogChanged'), hasLength(1));
    calls.clear();
    downloads.publish(music.tracks);
    await tester.pump();
    expect(calls, isEmpty);
    profiles.id = 'other';
    downloads.publish([]);
    await tester.pump();
    expect(calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    music.dispose();
    profiles.dispose();
  });

  Future<void> bluetoothScenario(
    WidgetTester tester,
    Future<void> Function(MusicDrivingRoutes, Music, Profiles, Future<void> Function(Object)) body,
  ) async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    late AppDatabase database;
    late MusicDrivingRoutes preferences;
    await tester.runAsync(() async {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      preferences = MusicDrivingRoutes(MusicLibraryStore(database, 'one'));
      await preferences.ready;
      await preferences.select(
        platform: 'ios',
        output: const MusicSystemAudioOutput(
          id: 'stable-system-id',
          name: 'Car',
          type: 'BluetoothA2DPOutput',
          bluetooth: true,
          channels: 2,
        ),
        current: () => true,
      );
    });
    const methods = MethodChannel('com.pleazyng/music_audio_route');
    const events = MethodChannel('com.pleazyng/music_audio_route/events');
    final binding = tester.binding, messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (_) async => route());
    messenger.setMockMethodCallHandler(events, (_) async => null);
    Future<void> emit(Object data) async {
      binding.channelBuffers.push(events.name, codec.encodeSuccessEnvelope(data), (_) {});
      await tester.pumpAndSettle();
    }

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final music = Music(), profiles = Profiles();
    try {
      await body(preferences, music, profiles, emit);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(events, null);
      preferences.dispose();
      music.dispose();
      profiles.dispose();
      await tester.runAsync(database.close);
      SettingsService.resetForTesting();
    }
  }

  testWidgets('selected Bluetooth opens driving once without projection or playback entitlement', (tester) async {
    await bluetoothScenario(tester, (preferences, music, profiles, emit) async {
      await mount(tester, music, profiles, drivingRoutes: preferences);
      await tester.pumpAndSettle();
      expect(find.byType(MusicDrivingScreen), findsOneWidget);
      expect(MusicBackgroundFrames.carConnected, isFalse);
      expect(music.pauses, 0);
      Navigator.of(tester.element(find.byType(MusicDrivingScreen))).pop();
      await tester.pumpAndSettle();
      await emit(route());
      expect(
        find.byType(MusicDrivingScreen),
        findsNothing,
        reason: 'A repeat snapshot must respect a manually dismissed automatic view',
      );
      final disconnected = route()..['outputs'] = <Object>[];
      await emit(disconnected);
      await emit(route());
      expect(find.byType(MusicDrivingScreen), findsOneWidget);
      await emit(disconnected);
      expect(find.byType(MusicDrivingScreen), findsNothing);
      expect(music.pauses, 0, reason: 'Bluetooth UI changes cannot issue a remote/group pause');
    });
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('Bluetooth driving respects profile binding and an unsuccessful PIN result', (tester) async {
    await bluetoothScenario(tester, (preferences, music, profiles, emit) async {
      profiles.binding = true;
      await mount(tester, music, profiles, drivingRoutes: preferences);
      await tester.pumpAndSettle();
      expect(find.byType(MusicDrivingScreen), findsNothing);
      profiles.binding = false;
      profiles.succeeded = false;
      profiles.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(MusicDrivingScreen), findsNothing);
      profiles.succeeded = true;
      profiles.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(MusicDrivingScreen), findsOneWidget);
    });
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('Bluetooth driving respects the automatic-entry master preference', (tester) async {
    await bluetoothScenario(tester, (preferences, music, profiles, emit) async {
      await SettingsService.instance.write(SettingsService.musicAutoDriving, false);
      await mount(tester, music, profiles, drivingRoutes: preferences);
      await tester.pumpAndSettle();
      expect(find.byType(MusicDrivingScreen), findsNothing);
      expect(MusicBackgroundFrames.carConnected, isFalse);
    });
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));
  testWidgets('profile replacement retires only its automatic driving route', (tester) async {
    await bluetoothScenario(tester, (preferences, music, profiles, emit) async {
      await mount(tester, music, profiles, drivingRoutes: preferences);
      await tester.pumpAndSettle();
      expect(find.byType(MusicDrivingScreen), findsOneWidget);
      profiles.id = 'two';
      profiles.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(MusicDrivingScreen), findsNothing);
      await emit(route());
      expect(find.byType(MusicDrivingScreen), findsNothing);
      expect(music.pauses, 0);
    });
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('a late Bluetooth inspection cannot open a retired profile', (tester) async {
    await bluetoothScenario(tester, (preferences, music, profiles, emit) async {
      final response = Completer<Object?>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.pleazyng/music_audio_route'),
        (_) => response.future,
      );
      await mount(tester, music, profiles, drivingRoutes: preferences);
      profiles.id = 'two';
      profiles.notifyListeners();
      response.complete(route());
      await tester.pumpAndSettle();
      expect(find.byType(MusicDrivingScreen), findsNothing);
      expect(MusicBackgroundFrames.carConnected, isFalse);
    });
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('Bluetooth disconnect preserves a manually opened route', (tester) async {
    await bluetoothScenario(tester, (preferences, music, profiles, emit) async {
      await mount(tester, music, profiles, drivingRoutes: preferences);
      await tester.pumpAndSettle();
      final navigator = Navigator.of(tester.element(find.byType(MusicDrivingScreen)));
      navigator.pop();
      await tester.pumpAndSettle();
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Manual driving view'))),
        ),
      );
      await tester.pumpAndSettle();
      await emit(route()..['outputs'] = <Object>[]);
      expect(find.text('Manual driving view'), findsOneWidget);
      expect(music.pauses, 0);
    });
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));
}
