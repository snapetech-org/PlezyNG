import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/music/music_queue_items.dart';
import 'package:plezy/services/music/music_tracks_loader.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import '../../test_helpers/music_experience_fakes.dart';

class _Pages extends ExperienceClient {
  int reads = 0;
  final libraries = <String?>[];
  late Future<LibraryPage<MediaItem>> Function(int start, int size) pageSource;
  @override
  Future<LibraryPage<MediaItem>> fetchMusicTracksPage(
    String id, {
    required MediaKind kind,
    String? libraryId,
    int? start,
    int? size,
    AbortController? abort,
  }) {
    reads++;
    libraries.add(libraryId);
    return pageSource(start ?? 0, size ?? 200);
  }
}

void main() {
  bool accepts(MediaItem item) => item.kind == MediaKind.track && item.serverId == 's' && item.libraryId == 'library';

  for (final kind in [MediaKind.album, MediaKind.artist]) {
    test('large $kind queue streams 10000 rows with stable duplicate occurrences', () async {
      final client = _Pages();
      client.pageSource = (start, size) async => LibraryPage(
        items: List.generate(size, (offset) => musicTrack('t$start-${offset % 10}')),
        totalCount: 10000,
        offset: start,
      );
      final items = await fetchMusicTracks(
        client,
        'container',
        kind: kind,
        libraryId: 'library',
        current: () => true,
        acceptsItem: accepts,
      );
      expect(items, isA<MusicQueueItemsSnapshot>());
      expect(items.length, 10000);
      expect(client.reads, 50);
      expect(client.libraries, List.filled(50, 'library'));
      expect(items.first.id, 't0-0');
      expect(items.last.id, 't9800-9');
      expect((items as MusicQueueItemsSnapshot).occurrenceAt(0), isNot(same(items.occurrenceAt(10))));
    });

    test('$kind rejects a bad page before another request', () async {
      final client = _Pages();
      client.pageSource = (start, size) async =>
          LibraryPage(items: [musicTrack('foreign').copyWith(serverId: 'foreign')], totalCount: 10000);
      await expectLater(
        fetchMusicTracks(client, 'container', kind: kind, current: () => true, acceptsItem: accepts),
        throwsStateError,
      );
      expect(client.reads, 1);
    });

    test('$kind retires an in-flight page before appending or requesting the next', () async {
      final client = _Pages();
      var current = true;
      final entered = Completer<void>(), response = Completer<LibraryPage<MediaItem>>();
      client.pageSource = (start, size) {
        entered.complete();
        return response.future;
      };
      final result = fetchMusicTracks(client, 'container', kind: kind, current: () => current, acceptsItem: accepts);
      final failed = expectLater(result, throwsStateError);
      await entered.future;
      current = false;
      response.complete(LibraryPage(items: [musicTrack('old')], totalCount: 10000));
      await failed;
      expect(client.reads, 1);
    });
  }

  for (final fault in ['offset', 'oversized', 'total', 'empty']) {
    test('rejects $fault paging rather than adopting a partial container', () async {
      final client = _Pages();
      client.pageSource = (_, _) async => LibraryPage(
        items: fault == 'empty' ? [] : List.filled(fault == 'oversized' ? 201 : 1, musicTrack('track')),
        offset: fault == 'offset' ? 1 : 0,
        totalCount: fault == 'total' ? 0 : 10000,
      );
      await expectLater(
        fetchMusicTracks(client, 'container', kind: MediaKind.album, current: () => true, acceptsItem: accepts),
        throwsFormatException,
      );
      expect(client.reads, 1);
    });
  }

  test('retired source performs no initial read', () async {
    final client = _Pages();
    await expectLater(
      fetchMusicTracks(client, 'container', kind: MediaKind.album, current: () => false, acceptsItem: accepts),
      throwsStateError,
    );
    expect(client.reads, 0);
  });
}
