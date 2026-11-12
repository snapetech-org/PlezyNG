import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/music/music_station_screen.dart';
import 'package:plezy/services/music/music_experience.dart';
import 'package:plezy/services/music/music_library_store.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/music/music_station.dart';
import 'package:plezy/services/playback_launch_observer.dart';
import '../../test_helpers/music_experience_fakes.dart';
import '../../test_helpers/prefs.dart';

class Libraries extends ChangeNotifier implements LibrariesProvider {
  @override
  List<MediaLibrary> get libraries => [
    const MediaLibrary(
      id: 'library',
      backend: MediaBackend.plex,
      title: 'Music',
      kind: MediaKind.artist,
      serverId: 's',
    ),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Hidden extends ChangeNotifier implements HiddenLibrariesProvider {
  @override
  Set<String> hiddenLibraryKeys = {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Profile extends ChangeNotifier implements ActiveProfileProvider {
  @override
  int identityMutationGeneration = 1;
  @override
  bool isBinding = false;
  @override
  bool lastBindingSucceeded = true;
  @override
  String get activeId => 'p';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Servers extends ChangeNotifier implements MultiServerProvider {
  ExperienceClient? client;
  @override
  MediaServerClient? getClientForServer(ServerId serverId) => client;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Downloads extends ChangeNotifier implements DownloadProvider {
  @override
  List<MediaItem> downloadedTracks = [musicTrack('owned')];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Music extends ExperienceMusic implements MusicStationRadioControls {
  MusicStationBatch? radio;
  @override
  Future<InstantMixOutcome> playStationRadio(
    MusicStationBatch preview, {
    MediaItem? startTrack,
    bool shuffle = false,
  }) async {
    if (!preview.isCurrent()) return InstantMixOutcome.superseded;
    radio = preview;
    return InstantMixOutcome.started;
  }

  int starts = 0;
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
    starts++;
    startedOffline = offline;
  }
}

void main() {
  for (final scenario in [
    'online',
    'authentication',
    'account',
    'hidden',
    'offline',
    'ownership',
    'foreign',
    'continuous',
    'continuous-offline',
    'profile',
    'binding',
  ]) {
    testWidgets('station preview validates its playback source: $scenario', (tester) async {
      resetSharedPreferencesForTest();
      if (scenario == 'continuous') {
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final store = MusicLibraryStore(database, 'p');
      final music = Music();
      final client = ExperienceClient()..rows = [musicTrack('online')];
      final servers = Servers()
        ..client = ['offline', 'ownership', 'foreign', 'continuous-offline'].contains(scenario) ? null : client;
      final libraries = Libraries();
      final hidden = Hidden();
      final profile = Profile();
      final downloads = Downloads();
      final experience = MusicExperience(music: music, store: store, clientFor: (_) => servers.client);
      await tester.runAsync(() async {
        await store.completeStationSnapshot('station', {
          'version': 1,
          'id': 'station',
          'tracks': [musicTrack('owned').toJson()],
        });
      });
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<MusicExperience>.value(value: experience),
            ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
            ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hidden),
            ChangeNotifierProvider<ActiveProfileProvider>.value(value: profile),
            ChangeNotifierProvider<MultiServerProvider>.value(value: servers),
            ChangeNotifierProvider<DownloadProvider>.value(value: downloads),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scenario == 'continuous' ? 2 : 1)),
              child: child!,
            ),
            home: MusicStationScreen(
              station: MusicStation(
                id: 'station',
                title: 'Station',
                serverId: 's',
                libraryId: 'library',
                continuous: scenario.startsWith('continuous'),
              ),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text(t.common.preview));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.common.preview));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pumpAndSettle();
      expect(music.starts, 0);
      if (scenario == 'authentication') client.authenticationSessionId = Object();
      if (scenario == 'account') client.scopedServerId = 's/other-account';
      if (scenario == 'profile') profile.identityMutationGeneration++;
      if (scenario == 'binding') profile.isBinding = true;
      if (scenario == 'hidden') hidden.hiddenLibraryKeys = {'s:library'};
      if (scenario == 'ownership') downloads.downloadedTracks = [];
      if (scenario == 'foreign') downloads.downloadedTracks = [musicTrack('owned').copyWith(libraryId: 'other')];
      await tester.ensureVisible(find.text(t.common.play));
      await tester.pumpAndSettle();
      expect(find.text(t.common.play).hitTestable(), findsOneWidget);
      await tester.tap(find.text(t.common.play));
      await tester.pumpAndSettle();
      final playable = ['online', 'offline', 'continuous', 'continuous-offline'].contains(scenario);
      expect(music.starts, playable && scenario != 'continuous' ? 1 : 0);
      expect(music.radio != null, scenario == 'continuous');
      if (scenario == 'continuous') expect(music.radio!.station.continuous, isTrue);
      if (!playable) expect(find.text(t.musicExperience.error), findsOneWidget);
      if (playable && scenario != 'continuous') {
        expect(music.startedOffline, ['offline', 'continuous-offline'].contains(scenario));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      experience.dispose();
      music.dispose();
      libraries.dispose();
      hidden.dispose();
      profile.dispose();
      servers.dispose();
      downloads.dispose();
      await tester.runAsync(database.close);
    });
  }
}
