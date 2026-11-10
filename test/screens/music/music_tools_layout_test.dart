import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/screens/music/music_home_screen.dart';
import 'package:plezy/screens/music/music_audio_screen.dart';
import 'package:plezy/screens/music/music_prompt_screen.dart';
import 'package:plezy/services/music/music_experience.dart';
import 'package:plezy/services/music/music_library_store.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import '../../test_helpers/music_experience_fakes.dart';

class Downloads extends ChangeNotifier implements DownloadProvider {
  @override
  List<MediaItem> get downloadedTracks => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final screen in <String, Widget>{
    'music home': const MusicHomeScreen(),
    'prompt playlist': const MusicPromptScreen(),
    'audio controls': const MusicAudioScreen(),
  }.entries) {
    testWidgets('${screen.key} remains scrollable at 320px and 200% text', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final music = ExperienceMusic();
      final downloads = Downloads();
      final experience = MusicExperience(music: music, store: MusicLibraryStore(database, 'p'), clientFor: (_) => null);
      await tester.runAsync(() => database.customSelect('SELECT 1').get());
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<MusicExperience>.value(value: experience),
            ChangeNotifierProvider<MusicPlaybackService>.value(value: music),
            ChangeNotifierProvider<DownloadProvider>.value(value: downloads),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: screen.value,
          ),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(Scrollable), findsWidgets);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      experience.dispose();
      music.dispose();
      downloads.dispose();
      await tester.runAsync(database.close);
    });
  }
}
