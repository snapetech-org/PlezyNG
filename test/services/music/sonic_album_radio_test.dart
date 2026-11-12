import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/music/sonic_album_radio.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import '../../test_helpers/media_items.dart';
import '../../test_helpers/music_experience_fakes.dart';

MediaItem album(String id, {String server = 's', String library = 'library'}) =>
    testMediaItem(id: id, kind: MediaKind.album, title: id, serverId: server, libraryId: library);

class _Client extends ExperienceClient {
  final requests = <(String, int, int)>[];
  final constraints = <(int, double)>[];
  Future<LibraryPage<MediaItem>> Function(String, int, int)? read;
  @override
  Future<List<MediaItem>> sonicallySimilar(String id, {int limit = 50, double maxDistance = .25}) async {
    constraints.add((limit, maxDistance));
    return rows;
  }

  @override
  Future<LibraryPage<MediaItem>> fetchMusicTracksPage(
    String id, {
    required MediaKind kind,
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final offset = start ?? 0, count = size ?? 200;
    requests.add((id, offset, count));
    if (read case final read?) return read(id, offset, count);
    final tracks = albums[id] ?? [];
    return LibraryPage(items: tracks.skip(offset).take(count).toList(), totalCount: tracks.length, offset: offset);
  }
}

void main() {
  late _Client client;
  late bool active;
  setUp(() {
    active = true;
    client = _Client()
      ..albums['a'] = [musicTrack('a2', album: 'a', disc: 2), musicTrack('a1', album: 'a')]
      ..albums['b'] = [musicTrack('b1', album: 'b'), musicTrack('b2', album: 'b', index: 2)]
      ..rows = [album('b')];
  });
  Future<List<MediaItem>> generate({int limit = 500, Set<String> excluded = const {}}) => buildSonicAlbumRadio(
    client: client,
    seed: album('a'),
    current: () => active,
    acceptsAlbum: (_) => true,
    acceptsTrack: (_) => true,
    maxDistance: .4,
    limit: limit,
    excludedAlbumIds: excluded,
  );
  test('selected album precedes complete similar albums in disc and track order', () async {
    expect((await generate()).map((t) => t.id), ['a1', 'a2', 'b1', 'b2']);
    expect(client.constraints, [(50, .4)]);
  });
  test('excluded and duplicate albums cannot repeat or fragment', () async {
    client.rows = [album('a'), album('b'), album('b')];
    expect((await generate(excluded: {'a'})).map((t) => t.id), ['b1', 'b2']);
    expect(client.requests.map((r) => r.$1), ['b']);
  });
  test('oversized similar albums are skipped whole while later albums fit', () async {
    client.albums['large'] = List.generate(10, (i) => musicTrack('large$i', album: 'large'));
    client.rows = [album('large'), album('b')];
    expect((await generate(limit: 4)).map((t) => t.id), ['a1', 'a2', 'b1', 'b2']);
  });
  test('removing one occurrence excludes the whole album on a refill', () async {
    final tracks = await buildSonicAlbumRadio(
      client: client,
      seed: album('a'),
      current: () => true,
      acceptsAlbum: (_) => true,
      acceptsTrack: (_) => true,
      excludedAlbumIds: {'a'},
      excludedTrackKeys: {'s:b1'},
    );
    expect(tracks, isEmpty);
  });

  test('oversized seed never becomes a truncated radio', () async {
    await expectLater(generate(limit: 1), throwsStateError);
    expect(client.constraints, isEmpty);
  });
  test('large albums use bounded pages and keep the final track', () async {
    client.albums['a'] = List.generate(450, (i) => musicTrack('a$i', album: 'a', index: i + 1));
    client.rows = [];
    expect(await generate(), hasLength(450));
    expect(client.requests, [('a', 0, 200), ('a', 200, 200), ('a', 400, 200)]);
  });
  test('foreign neighbors do not trigger metadata reads', () async {
    client.rows = [album('foreign', server: 'other'), album('hidden', library: 'other'), album('b')];
    expect(await generate(), hasLength(4));
    expect(client.requests.map((r) => r.$1), ['a', 'b']);
  });
  for (final invalid in ['offset', 'empty', 'parent', 'library', 'server', 'duplicate', 'total']) {
    test('malformed $invalid page cannot enter a radio batch', () async {
      client.read = (id, start, size) async {
        final row = musicTrack(
          'x',
          album: invalid == 'parent' ? 'wrong' : id,
          server: invalid == 'server' ? 'other' : 's',
        );
        return LibraryPage(
          items: invalid == 'empty'
              ? []
              : [invalid == 'library' ? row.copyWith(libraryId: 'other') : row, if (invalid == 'duplicate') row],
          totalCount: invalid == 'duplicate'
              ? 2
              : invalid == 'total'
              ? -1
              : 1,
          offset: invalid == 'offset' ? 1 : start,
        );
      };
      await expectLater(generate(), throwsStateError);
    });
  }
  for (final change in ['authentication', 'account', 'profile']) {
    test('$change retirement during a page rejects the entire result', () async {
      final pending = Completer<LibraryPage<MediaItem>>();
      client.read = (_, _, _) => pending.future;
      final result = generate();
      final rejected = expectLater(result, throwsStateError);
      if (change == 'authentication') client.authenticationSessionId = Object();
      if (change == 'account') client.scopedServerId = 's/other-account';
      if (change == 'profile') active = false;
      pending.complete(LibraryPage(items: [musicTrack('a1', album: 'a')], totalCount: 1, offset: 0));
      await rejected;
    });
  }
}
