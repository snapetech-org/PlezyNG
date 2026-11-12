import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/playback_launch_observer.dart';
import 'package:plezy/utils/music_navigation.dart';
import 'package:provider/provider.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/stub_music_playback_service.dart';

class _Music extends StubMusicPlaybackService {
  int starts = 0;
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
  }
}

void main() {
  for (final mode in ['before', 'success', 'empty', 'error']) {
    testWidgets('source retirement guards $mode fetched playback', (tester) async {
      final music = _Music();
      var current = mode != 'before', fetches = 0, feedback = 0;
      late BuildContext context;
      await tester.pumpWidget(
        ChangeNotifierProvider<MusicPlaybackService>.value(
          value: music,
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
      final pending = Completer<List<MediaItem>>();
      final result = playFetchedTracks(
        context,
        fetch: () {
          fetches++;
          return pending.future;
        },
        sourceCurrent: () => current,
        playContext: const MusicPlayContext(title: 'Music', kind: MusicPlayContextKind.playlist),
        onEmpty: () => feedback++,
        onError: (_, _) => feedback++,
      );
      if (mode != 'before') {
        current = false;
        if (mode == 'error') {
          pending.completeError(StateError('retired'));
        } else {
          pending.complete(mode == 'empty' ? [] : [testMediaItem(kind: MediaKind.track)]);
        }
      }
      await result;
      expect(fetches, mode == 'before' ? 0 : 1);
      expect(music.starts, 0);
      expect(feedback, 0);
      expect(tester.takeException(), isNull);
      music.dispose();
    });
  }
}
