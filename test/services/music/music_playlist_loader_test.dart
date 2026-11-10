import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/services/music/music_playlist_loader.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import '../../test_helpers/music_experience_fakes.dart';

class PlaylistClient extends ExperienceClient {
  Future<LibraryPage<MediaItem>> Function(int)? playlist;
  @override
  Future<LibraryPage<MediaItem>> fetchPlaylistPage(String id, {int? start, int? size, AbortController? abort}) =>
      playlist!(start ?? 0);
}

void main() {
  test('native playlist expansion preserves every occurrence and server identity', () async {
    final client = PlaylistClient()
      ..playlist = (offset) async => LibraryPage(
        items: offset == 0
            ? [musicTrack('a'), musicTrack('b')]
            : [musicTrack('a'), musicTrack('foreign', server: 'other')],
        totalCount: 4,
      );
    expect((await loadMusicPlaylist(client, 'list', current: () => true)).map((t) => t.id), ['a', 'b', 'a']);
  });
  test('account replacement or cancellation discards partially resolved playlists', () async {
    for (final replace in [true, false]) {
      var active = true;
      final client = PlaylistClient();
      client.playlist = (offset) async {
        if (offset > 0) {
          if (replace) {
            client.authenticationSessionId = Object();
          } else {
            active = false;
          }
        }
        return LibraryPage(items: [musicTrack('a')], totalCount: 2);
      };
      await expectLater(loadMusicPlaylist(client, 'list', current: () => active), throwsStateError);
    }
  });
  test('unbounded or inconsistent playlists fail instead of silently truncating playback', () async {
    final client = PlaylistClient()..playlist = (_) async => LibraryPage(items: [musicTrack('a')], totalCount: 200001);
    await expectLater(loadMusicPlaylist(client, 'list', current: () => true), throwsStateError);
  });
}
