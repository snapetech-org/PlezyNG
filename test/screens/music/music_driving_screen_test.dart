import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/screens/music/music_driving_screen.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:provider/provider.dart';
import '../../test_helpers/media_items.dart';
import '../../test_helpers/stub_music_playback_service.dart';

class Music extends StubMusicPlaybackService {
  int toggles = 0;
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

void main() {
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
