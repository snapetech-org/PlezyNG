import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
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
  List<MediaItem> downloadedTracks = [];
  @override
  bool isDownloaded(String key) => downloadedTracks.any((item) => item.globalKey == key);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Client extends ExperienceClient {
  int reads = 0;
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
}
