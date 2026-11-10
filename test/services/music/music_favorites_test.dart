import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/services/music/music_favorites.dart';

import '../../test_helpers/music_experience_fakes.dart';

MediaItem favorite(String id, {String server = 's', String library = 'library', bool liked = true}) =>
    MediaItem.fromJson({...musicTrack(id, server: server).toJson(), 'libraryId': library, 'isFavorite': liked});

void main() {
  test('favorites reject ignored filters, foreign libraries and non-track rows', () async {
    final client = ExperienceClient()
      ..rows = [
        favorite('yes'),
        favorite('no', liked: false),
        favorite('foreign-server', server: 'other'),
        favorite('foreign-library', library: 'other'),
        MediaItem.fromJson({...favorite('album').toJson(), 'kind': MediaKind.album.name}),
      ];
    final selection = await MusicFavoriteSelection.load([
      MusicFavoriteSource(client: client, libraryId: 'library', isCurrent: () => true),
    ]);
    expect(selection.tracks.map((track) => track.id), ['yes']);
    expect(client.queries.single.filters.single.op, LibraryFilterOperator.is_);
  });

  test('Plex-style numeric favorites require at least eight stars', () async {
    final client = ExperienceClient()
      ..capabilities = const ServerCapabilities(numericUserRating: true)
      ..rows = [
        MediaItem.fromJson({...musicTrack('yes').toJson(), 'userRating': 8}),
        MediaItem.fromJson({...musicTrack('no').toJson(), 'userRating': 7}),
        musicTrack('unrated'),
      ];
    final selection = await MusicFavoriteSelection.load([
      MusicFavoriteSource(client: client, libraryId: 'library', isCurrent: () => true),
    ]);
    expect(selection.tracks.map((track) => track.id), ['yes']);
    expect(client.queries.single.filters.single.op, LibraryFilterOperator.atLeast);
  });

  test('completed results stop being playable after account or visibility changes', () async {
    final client = ExperienceClient()..rows = [favorite('yes')];
    var visible = true;
    final selection = await MusicFavoriteSelection.load([
      MusicFavoriteSource(client: client, libraryId: 'library', isCurrent: () => visible),
    ]);
    expect(selection.tracks, hasLength(1));
    visible = false;
    expect(selection.tracks, isEmpty);
    visible = true;
    client.scopedServerId = 's/another-account';
    expect(selection.tracks, isEmpty);
  });

  test('all sources are revalidated after the slowest fetch completes', () async {
    final first = ExperienceClient()..rows = [favorite('first')];
    final pending = Completer<LibraryPage<MediaItem>>();
    final second = ExperienceClient()..page = (_) => pending.future;
    final result = MusicFavoriteSelection.load([
      MusicFavoriteSource(client: first, libraryId: 'library', isCurrent: () => true),
      MusicFavoriteSource(client: second, libraryId: 'library', isCurrent: () => true),
    ]);
    first.authenticationSessionId = Object();
    pending.complete(LibraryPage(items: [favorite('second')], totalCount: 1));
    expect((await result).tracks.map((track) => track.id), ['second']);
  });

  test('offline and unsupported sources do not query the network', () async {
    final offline = ExperienceClient()..isOfflineMode = true;
    final unsupported = ExperienceClient()..capabilities = const ServerCapabilities();
    final selection = await MusicFavoriteSelection.load([
      for (final client in [offline, unsupported])
        MusicFavoriteSource(client: client, libraryId: 'library', isCurrent: () => true),
    ]);
    expect(selection.tracks, isEmpty);
    expect(offline.queries, isEmpty);
    expect(unsupported.queries, isEmpty);
  });
}
