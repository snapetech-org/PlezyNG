import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/music/music_driving_screen.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:provider/provider.dart';
import '../../test_helpers/media_items.dart';
import '../../test_helpers/stub_music_playback_service.dart';

class Music extends StubMusicPlaybackService {
  int toggles = 0;
  int starts = 0;
  bool? startedOffline;
  List<MediaItem> startedTracks = [];
  @override
  Future<void> playFromList({
    required List<MediaItem> tracks,
    MediaItem? startTrack,
    required MusicPlayContext playContext,
    bool shuffle = false,
    Duration? initialPosition,
    bool offline = false,
    dynamic launchObserver,
  }) async {
    starts++;
    startedOffline = offline;
    startedTracks = tracks;
  }

  @override
  MediaItem get currentTrack => testMediaItem(
    id: 'a',
    kind: MediaKind.track,
    title: 'A long album title and a very long track title',
    grandparentTitle: 'Artist',
  );
  @override
  Future<void> togglePlayPause() async {
    toggles++;
  }
}

class Downloads extends ChangeNotifier implements DownloadProvider {
  List<MediaItem> tracks = [testMediaItem(id: 'downloaded', kind: MediaKind.track, title: 'Offline song')];
  @override
  List<MediaItem> get downloadedTracks => tracks;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final revoke in [false, true]) {
    testWidgets('driving downloads require explicit selection and recheck ownership: $revoke', (tester) async {
      final music = Music();
      final downloads = Downloads();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<MusicPlaybackService>.value(value: music),
            ChangeNotifierProvider<DownloadProvider>.value(value: downloads),
          ],
          child: const MaterialApp(home: MusicDrivingScreen()),
        ),
      );
      expect(music.starts, 0);
      await tester.ensureVisible(find.text(t.navigation.downloads));
      await tester.tap(find.text(t.navigation.downloads));
      await tester.pumpAndSettle();
      expect(music.starts, 0);
      if (revoke) downloads.tracks = [];
      await tester.tap(find.text('Offline song'));
      await tester.pumpAndSettle();
      expect(music.starts, revoke ? 0 : 1);
      if (!revoke) {
        expect(music.startedOffline, isTrue);
        expect(music.startedTracks.single.id, 'downloaded');
      }
      await tester.pumpWidget(const SizedBox());
      music.dispose();
      downloads.dispose();
    });
  }
  testWidgets('driving view reuses transport and fits a narrow screen at large text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final music = Music();
    await tester.pumpWidget(
      ChangeNotifierProvider<MusicPlaybackService>.value(
        value: music,
        child: MaterialApp(
          builder: (_, child) => MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: const MusicDrivingScreen(),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byIcon(Symbols.play_arrow_rounded));
    await tester.tap(find.byIcon(Symbols.play_arrow_rounded));
    expect(music.toggles, 1);
  });
}
