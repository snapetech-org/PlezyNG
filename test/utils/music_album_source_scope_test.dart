import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_playlist.dart';
import 'package:plezy/utils/music_read_scope.dart';
import 'package:plezy/services/music/music_queue_items.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/playback_launch_observer.dart';
import 'package:plezy/utils/music_navigation.dart';
import 'package:provider/provider.dart';
import '../test_helpers/music_experience_fakes.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/stub_music_playback_service.dart';

class _Profile extends ChangeNotifier implements ActiveProfileProvider {
  @override
  Profile active = Profile.local(id: 'p', displayName: 'Listener', createdAt: DateTime.utc(2024));
  @override
  String get activeId => active.id;
  @override
  bool isBinding = false;
  @override
  bool lastBindingSucceeded = true;
  @override
  int identityMutationGeneration = 1;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Hidden extends ChangeNotifier implements HiddenLibrariesProvider {
  @override
  bool isDisposed = false, isInitialized = true;
  @override
  String profileId = 'p';
  @override
  Set<String> hiddenLibraryKeys = {};
  Future<void> Function()? ready;
  @override
  Future<void> ensureInitialized() async {
    await ready?.call();
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Files extends ChangeNotifier implements DownloadProvider {
  @override
  String? activeProfileId = 'p';
  @override
  bool isDisposed = false;
  @override
  List<MediaItem> get downloadedTracks => _tracks;
  List<MediaItem> _tracks = [];
  Set<String> _keys = {};
  int ownershipReads = 0;
  set downloadedTracks(List<MediaItem> tracks) {
    _tracks = List.unmodifiable(tracks);
    _keys = tracks.map((track) => track.globalKey).toSet();
  }

  @override
  bool isDownloaded(String key) {
    ownershipReads++;
    return _keys.contains(key);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Client extends ExperienceClient {
  int reads = 0, playlistReads = 0;
  Future<LibraryPage<MediaItem>> Function(int start, int size)? playlistPage;
  @override
  Future<LibraryPage<MediaItem>> fetchPlaylistPage(String id, {int? start, int? size, AbortController? abort}) async {
    playlistReads++;
    return playlistPage?.call(start ?? 0, size ?? 200) ?? LibraryPage(items: [musicTrack('first')], totalCount: 1);
  }

  Future<List<MediaItem>> Function()? album;
  @override
  Future<List<MediaItem>> fetchAlbumTracks(String id) async {
    reads++;
    return album?.call() ?? super.fetchAlbumTracks(id);
  }
}

class _Music extends StubMusicPlaybackService {
  List<MediaItem>? started;
  bool? offlineStart;
  MediaItem? start;
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
    start = startTrack;
    offlineStart = offline;
  }
}

void main() {
  Future<
    ({
      BuildContext context,
      _Client client,
      _Profile profile,
      _Hidden hidden,
      _Files files,
      _Music music,
      MultiServerProvider servers,
    })
  >
  pump(WidgetTester tester, {bool online = true}) async {
    final profile = _Profile(), hidden = _Hidden(), files = _Files(), music = _Music(), client = _Client();
    final servers = testMultiServer(clients: online ? [client] : []);
    addTearDown(profile.dispose);
    addTearDown(hidden.dispose);
    addTearDown(files.dispose);
    addTearDown(music.dispose);
    late BuildContext context;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ActiveProfileProvider>.value(value: profile),
          ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hidden),
          ChangeNotifierProvider<DownloadProvider>.value(value: files),
          ChangeNotifierProvider<MusicPlaybackService>.value(value: music),
          ChangeNotifierProvider<MultiServerProvider>.value(value: servers.provider),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return (
      context: context,
      client: client,
      profile: profile,
      hidden: hidden,
      files: files,
      music: music,
      servers: servers.provider,
    );
  }

  final seed = musicTrack('second');
  testWidgets('authorized album starts the selected exact track', (tester) async {
    final h = await pump(tester);
    h.client.albums['album'] = [musicTrack('first'), seed];
    await playTrackWithAlbumContext(h.context, seed);
    expect(h.music.started?.map((item) => item.id), ['first', 'second']);
    expect(h.music.start, same(seed));
    expect(h.music.offlineStart, isFalse);
  });

  for (final change in ['authentication', 'account', 'profile', 'binding', 'hidden', 'client', 'intent']) {
    testWidgets('$change change during album fetch cannot replace playback', (tester) async {
      final h = await pump(tester), pending = Completer<List<MediaItem>>();
      h.client.album = () => pending.future;
      final result = playTrackWithAlbumContext(h.context, seed);
      await tester.pump();
      expect(h.client.reads, 1);
      switch (change) {
        case 'authentication':
          h.client.authenticationSessionId = Object();
        case 'account':
          h.client.scopedServerId = 's/replacement';
        case 'profile':
          h.profile.identityMutationGeneration++;
        case 'binding':
          h.profile.isBinding = true;
        case 'hidden':
          h.hidden.hiddenLibraryKeys.add('s:library');
        case 'client':
          h.servers.serverManager.debugRegisterClientForTesting(_Client());
        case 'intent':
          h.music.beginPlayIntent();
      }
      pending.complete([musicTrack('first'), seed]);
      await result;
      expect(h.music.started, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  for (final foreign in ['server', 'library', 'parent']) {
    testWidgets('a $foreign album response cannot form a queue from foreign rows', (tester) async {
      final h = await pump(tester);
      final wrong = switch (foreign) {
        'server' => seed.copyWith(serverId: 'other'),
        'library' => seed.copyWith(libraryId: 'other'),
        _ => seed.copyWith(parentId: 'other'),
      };
      h.client.albums['album'] = [musicTrack('first'), wrong];
      await playTrackWithAlbumContext(h.context, seed);
      expect(h.music.started, [seed]);
      expect(h.music.start, isNull);
    });
  }

  for (final owned in ['owned', 'missing', 'other-profile', 'other-backend']) {
    testWidgets('offline $owned track preserves the active profile ownership boundary', (tester) async {
      final h = await pump(tester, online: false);
      if (owned != 'missing') h.files.downloadedTracks = [seed];
      if (owned == 'other-profile') h.files.activeProfileId = 'other';
      if (owned == 'other-backend') {
        h.files.downloadedTracks = [
          MediaItem(id: seed.id, backend: MediaBackend.jellyfin, kind: seed.kind, serverId: seed.serverId),
        ];
      }
      await playTrackWithAlbumContext(h.context, seed);
      if (owned == 'owned') {
        expect(h.music.started, [seed]);
        expect(h.music.offlineStart, isTrue);
      } else {
        expect(h.music.started, isNull);
      }
      expect(h.client.reads, 0);
    });
  }

  for (final retire in [false, true]) {
    testWidgets('failed album read fallback, retired=$retire', (tester) async {
      final h = await pump(tester);
      h.client.album = () async {
        if (retire) h.client.authenticationSessionId = Object();
        throw StateError('not available');
      };
      await playTrackWithAlbumContext(h.context, seed);
      expect(h.music.started, retire ? isNull : [seed]);
    });
  }

  testWidgets('profile retirement while hidden libraries initialize starts no server read', (tester) async {
    final h = await pump(tester), pending = Completer<void>();
    h.hidden.ready = () => pending.future;
    final result = playTrackWithAlbumContext(h.context, seed);
    h.profile.identityMutationGeneration++;
    pending.complete();
    await result;
    expect(h.client.reads, 0);
    expect(h.music.started, isNull);
  });
  testWidgets('an offline client uses only the active profile owned file', (tester) async {
    final h = await pump(tester);
    h.client.isOfflineMode = true;
    h.files.downloadedTracks = [seed];
    await playTrackWithAlbumContext(h.context, seed);
    expect(h.music.started, [seed]);
    expect(h.music.offlineStart, isTrue);
    expect(h.client.reads, 0);
  });

  testWidgets('failed hidden-library initialization cannot start a remote read', (tester) async {
    final h = await pump(tester);
    h.hidden.ready = () async => throw StateError('unavailable');
    await playTrackWithAlbumContext(h.context, seed);
    expect(h.client.reads, 0);
    expect(h.music.started, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('explicit offline navigation never fetches a live album', (tester) async {
    final h = await pump(tester);
    h.files.downloadedTracks = [seed];
    await playTrackWithAlbumContext(h.context, seed, isOffline: true);
    expect(h.music.started, [seed]);
    expect(h.music.offlineStart, isTrue);
    expect(h.client.reads, 0);
  });
  const playlist = MediaPlaylist(
    id: 'list',
    backend: MediaBackend.plex,
    title: 'Music',
    playlistType: 'audio',
    serverId: 's',
  );

  testWidgets('an unreachable explicit playlist client cannot fall back to owned downloads', (tester) async {
    final h = await pump(tester);
    h.files.downloadedTracks = [musicTrack('first')];
    h.servers.serverManager.debugRegisterClientForTesting(h.client, online: false);
    await playAudioPlaylist(h.context, client: h.client, playlist: playlist, preloadedItems: h.files.downloadedTracks);
    expect(h.music.started, isNull);
    expect(h.client.playlistReads, 0);
  });

  testWidgets('playlist paging preserves duplicate occurrences and selected entry', (tester) async {
    final h = await pump(tester);
    final first = musicTrack('first');
    final second = musicTrack('first');
    h.client.playlistPage = (start, size) async => LibraryPage(items: start == 0 ? [first] : [second], totalCount: 2);
    await playAudioPlaylist(h.context, client: h.client, playlist: playlist, startTrack: second);
    expect(h.client.playlistReads, 2);
    expect(h.music.started, [first, second]);
    expect(h.music.start, same(second));
  });

  for (final change in ['authentication', 'profile', 'binding', 'account', 'client', 'hidden', 'caller', 'intent']) {
    testWidgets('playlist $change retirement stops before the next page', (tester) async {
      final h = await pump(tester);
      var callerCurrent = true;
      h.client.playlistPage = (start, size) async {
        switch (change) {
          case 'authentication':
            h.client.authenticationSessionId = Object();
          case 'profile':
            h.profile.identityMutationGeneration++;
          case 'binding':
            h.profile.isBinding = true;
          case 'account':
            h.client.scopedServerId = 's/other';
          case 'client':
            h.servers.serverManager.debugRegisterClientForTesting(_Client());
          case 'hidden':
            h.hidden.hiddenLibraryKeys.add('s:library');
          case 'caller':
            callerCurrent = false;
          case 'intent':
            h.music.beginPlayIntent();
        }
        // Hide a track, not the library-less playlist record.
        return LibraryPage(items: [musicTrack('first')], totalCount: 2);
      };
      await playAudioPlaylist(h.context, client: h.client, playlist: playlist, sourceCurrent: () => callerCurrent);
      expect(h.client.playlistReads, 1);
      expect(h.music.started, isNull);
    });
  }

  for (final bad in ['backend', 'server', 'kind']) {
    testWidgets('playlist rejects a foreign $bad row', (tester) async {
      final h = await pump(tester);
      final invalid = switch (bad) {
        'backend' => MediaItem(id: 'bad', backend: MediaBackend.jellyfin, kind: MediaKind.track, serverId: 's'),
        'server' => musicTrack('bad', server: 'other'),
        _ => MediaItem(id: 'bad', backend: MediaBackend.plex, kind: MediaKind.movie, serverId: 's'),
      };
      h.client.playlistPage = (_, _) async => LibraryPage(items: [invalid], totalCount: 1);
      var errors = 0;
      await playAudioPlaylist(h.context, client: h.client, playlist: playlist, onError: (_, _) => errors++);
      expect(h.music.started, isNull);
      expect(errors, 1);
    });
  }

  testWidgets('offline playlist keeps owned duplicate occurrences and performs no network read', (tester) async {
    final h = await pump(tester);
    final duplicate = musicTrack(seed.id);
    h.files.downloadedTracks = [seed];
    await playAudioPlaylist(
      h.context,
      client: h.client,
      playlist: playlist,
      isOffline: true,
      preloadedItems: [seed, duplicate],
      startTrack: duplicate,
    );
    expect(h.music.started, [seed, duplicate]);
    expect(h.music.start, same(duplicate));
    expect(h.music.offlineStart, isTrue);
    expect(h.client.playlistReads, 0);
  });

  testWidgets('offline playlist cannot include an unowned file', (tester) async {
    final h = await pump(tester);
    h.files.downloadedTracks = [seed];
    await playAudioPlaylist(
      h.context,
      client: h.client,
      playlist: playlist,
      isOffline: true,
      preloadedItems: [seed, musicTrack('missing')],
    );
    expect(h.music.started, isNull);
    expect(h.client.playlistReads, 0);
  });

  testWidgets('profile change while preparing a playlist suppresses all reads', (tester) async {
    final h = await pump(tester), pending = Completer<void>();
    h.hidden.ready = () => pending.future;
    final result = playAudioPlaylist(h.context, client: h.client, playlist: playlist);
    h.profile.identityMutationGeneration++;
    pending.complete();
    await result;
    expect(h.music.started, isNull);
    expect(h.client.playlistReads, 0);
  });

  testWidgets('newer play intent wins while playlist source initializes', (tester) async {
    final h = await pump(tester), pending = Completer<void>();
    h.hidden.ready = () => pending.future;
    final result = playAudioPlaylist(h.context, client: h.client, playlist: playlist);
    h.music.beginPlayIntent();
    pending.complete();
    await result;
    expect(h.music.started, isNull);
    expect(h.client.playlistReads, 0);
  });

  testWidgets('offline album menu scope uses only owned children in disc order', (tester) async {
    final h = await pump(tester);
    h.files.downloadedTracks = [
      musicTrack('third', disc: 2),
      seed,
      musicTrack('first'),
      musicTrack('foreign', album: 'elsewhere'),
    ];
    final album = MediaItem(
      id: 'album',
      backend: MediaBackend.plex,
      kind: MediaKind.album,
      serverId: 's',
      libraryId: 'library',
    );
    final scope = await MusicReadScope.forItem(h.context, album, offline: true);
    expect(scope?.offlineTracks.map((item) => item.id), [seed.id, 'first', 'third']);
    expect(h.client.reads, 0);
    h.files.activeProfileId = 'other';
    expect(scope?.current, isFalse);
  });

  testWidgets('live container expansion rejects another album and hidden library rows', (tester) async {
    final h = await pump(tester);
    final album = MediaItem(
      id: 'album',
      backend: MediaBackend.plex,
      kind: MediaKind.album,
      serverId: 's',
      libraryId: 'library',
    );
    final scope = await MusicReadScope.forItem(h.context, album);
    expect(scope?.ownsTrack(seed), isTrue);
    expect(scope?.ownsTrack(musicTrack('foreign', album: 'elsewhere')), isFalse);
    h.hidden.hiddenLibraryKeys.add('s:library');
    expect(scope?.current, isFalse);
  });
  testWidgets('large playlist admission returns a metadata window rather than a full decoded list', (tester) async {
    final h = await pump(tester);
    h.client.playlistPage = (start, size) async => LibraryPage(
      items: [for (var i = start; i < (start + size).clamp(0, 10000); i++) musicTrack('$i')],
      totalCount: 10000,
    );
    await playAudioPlaylist(h.context, client: h.client, playlist: playlist);
    expect(h.client.playlistReads, 50);
    expect(h.music.started, isA<MusicQueueItemsSnapshot>());
    expect(h.music.started?.length, 10000);
    expect(h.music.started?.first.id, '0');
    expect(h.music.started?.last.id, '9999');
  });

  testWidgets('invalid playlist page stops admission before more requests', (tester) async {
    final h = await pump(tester);
    h.client.playlistPage = (_, _) async =>
        LibraryPage(items: [musicTrack('foreign', server: 'other')], totalCount: 10000);
    var errors = 0;
    await playAudioPlaylist(h.context, client: h.client, playlist: playlist, onError: (_, _) => errors++);
    expect(h.client.playlistReads, 1);
    expect(h.music.started, isNull);
    expect(errors, 1);
  });

  testWidgets('large owned offline playlist retains occurrence order through one batch check', (tester) async {
    final h = await pump(tester);
    final tracks = [for (var i = 0; i < 10000; i++) musicTrack('$i')];
    h.files.downloadedTracks = tracks;
    await playAudioPlaylist(h.context, client: h.client, playlist: playlist, isOffline: true, preloadedItems: tracks);
    expect(h.music.started?.length, 10000);
    expect(h.music.started?.last.id, '9999');
    expect(h.files.ownershipReads, lessThan(100000));
    expect(h.client.playlistReads, 0);
    expect(h.music.offlineStart, isTrue);
  });
}
