import 'dart:async';
import 'package:plezy/services/music/server_music_radio.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/music/music_server_recommendations.dart';

import '../../test_helpers/music_experience_fakes.dart';

class _Client extends ExperienceClient {
  Future<List<MediaHub>> Function(String, HubFetchDiagnostics?)? fetch;
  final requests = <String>[];
  final limits = <int>[];
  @override
  Future<List<MediaHub>> fetchLibraryHubs(
    String libraryId, {
    required String libraryName,
    int limit = 12,
    bool includePlaybackHubs = true,
    MediaKind? libraryKind,
    HubFetchDiagnostics? diagnostics,
  }) async {
    expect(libraryKind, MediaKind.artist);
    expect(includePlaybackHubs, isFalse);
    requests.add(libraryId);
    limits.add(limit);
    return fetch == null ? [hub()] : fetch!(libraryId, diagnostics);
  }
}

class _RadioClient extends _Client implements ServerMusicRadioClient {
  List<ServerMusicRadio> radioRows = [];
  bool radioFailure = false;
  Future<List<ServerMusicRadio>>? pendingRadios;
  @override
  Future<List<ServerMusicRadio>> serverMusicRadios(String libraryId) async {
    if (radioFailure) throw StateError('Forbidden radio');
    return pendingRadios ?? radioRows;
  }

  @override
  bool serverMusicRadioCurrent(ServerMusicRadio radio) => radioRows.any((row) => identical(row, radio));
  @override
  Future<List<MediaItem>> serverMusicRadioTracks(ServerMusicRadio radio, {int limit = 100}) async => [];
}

MediaHub hub({String id = 'server-family', String server = 's', String? library, List<MediaItem>? items}) => MediaHub(
  id: id,
  identifier: 'music.server.actual-family',
  title: 'The server family',
  type: 'track',
  serverId: server,
  libraryId: library,
  items: items ?? [musicTrack('one')],
  size: 50,
  more: true,
);
MusicRecommendationSource _source(_Client client, {String id = 'library', bool Function()? current}) =>
    MusicRecommendationSource(client: client, libraryId: id, libraryName: id, isCurrent: current ?? () => true);
MediaItem item(String id, String library) => MediaItem.fromJson({...musicTrack(id).toJson(), 'libraryId': library});

void main() {
  const radio = ServerMusicRadio(
    serverId: 's',
    libraryId: 'library',
    key: '/library/metadata/1/station/radio?type=10',
    title: 'Radio family',
  );
  test('radio families retain their exact source and retire with authorization', () async {
    final client = _RadioClient()
      ..radioRows = [
        radio,
        radio,
        const ServerMusicRadio(
          serverId: 'foreign',
          libraryId: 'library',
          key: '/library/metadata/2/station/radio',
          title: 'Foreign',
        ),
      ];
    var current = true;
    final selection = await MusicServerRecommendations.load([_source(client, current: () => current)]);
    final entry = selection.radios.single;
    expect(identical(entry.radio, radio), isTrue);
    expect(selection.shelves, hasLength(1));
    client.radioRows = [];
    expect(entry.isCurrent, isFalse);
    expect(selection.radios, isEmpty);
    current = false;
    expect(selection.shelves, isEmpty);
  });

  test('radio failure is visible without discarding valid album recommendations', () async {
    final client = _RadioClient()..radioFailure = true;
    final selection = await MusicServerRecommendations.load([_source(client)]);
    expect(selection.hasFailures, isTrue);
    expect(selection.radios, isEmpty);
    expect(selection.shelves, hasLength(1));
  });

  test('a late radio catalog cannot outlive its original authentication', () async {
    final client = _RadioClient()..radioRows = [radio];
    final pending = Completer<List<ServerMusicRadio>>();
    client.pendingRadios = pending.future;
    final load = MusicServerRecommendations.load([_source(client)]);
    await Future<void>.delayed(Duration.zero);
    client.authenticationSessionId = Object();
    pending.complete([radio]);
    expect((await load).radios, isEmpty);
  });

  test('previews preserve native family identity and reject foreign or non-music rows', () async {
    final client = _Client();
    client.fetch = (_, _) async => [
      hub(
        items: [
          musicTrack('one'),
          musicTrack('one'),
          musicTrack('foreign-server', server: 'other'),
          MediaItem.fromJson({...musicTrack('foreign-library').toJson(), 'libraryId': 'other'}),
          MediaItem.fromJson({...musicTrack('unknown-library').toJson(), 'libraryId': null}),
          MediaItem.fromJson({...musicTrack('foreign-backend').toJson(), 'backend': 'jellyfin'}),
          MediaItem.fromJson({...musicTrack('video').toJson(), 'kind': 'movie'}),
        ],
      ),
      hub(id: 'wrong-server', server: 'other'),
      hub(id: 'wrong-library', library: 'other'),
      hub(id: 'server-family'),
    ];
    final result = await MusicServerRecommendations.load([_source(client)]);
    final shelf = result.shelves.single;
    expect(shelf.hub.items.map((row) => row.id), ['one']);
    expect(shelf.hub.identifier, 'music.server.actual-family');
    expect(shelf.hub.title, 'The server family');
    expect(shelf.hub.size, 50);
    expect(shelf.hub.more, isTrue);
    expect(client.limits, [12]);
    expect(() => shelf.hub.items.clear(), throwsUnsupportedError);
    expect(() => result.shelves.clear(), throwsUnsupportedError);
  });

  test('completed previews and retained actions retire with account, authentication or visibility', () async {
    final client = _Client();
    var visible = true;
    final result = await MusicServerRecommendations.load([_source(client, current: () => visible)]);
    final retained = result.shelves.single;
    visible = false;
    expect(result.shelves, isEmpty);
    expect(retained.isCurrent, isFalse);
    visible = true;
    expect(retained.isCurrent, isTrue);
    client.authenticationSessionId = Object();
    expect(result.shelves, isEmpty);
    final fresh = await MusicServerRecommendations.load([_source(client)]);
    client.scopedServerId = 's/another-account';
    expect(fresh.shelves, isEmpty);
  });

  test('the slowest request cannot preserve another source that has retired', () async {
    final first = _Client(), second = _Client();
    final gate = Completer<List<MediaHub>>();
    second.fetch = (_, _) => gate.future;
    final future = MusicServerRecommendations.load([_source(first), _source(second)]);
    first.scopedServerId = 's/another-account';
    gate.complete([hub(id: 'second')]);
    expect((await future).shelves.map((row) => row.hub.id), ['second']);
  });

  test('queued sources pin ownership before bounded parallel requests begin', () async {
    final clients = List.generate(5, (_) => _Client());
    final gates = List.generate(4, (_) => Completer<List<MediaHub>>());
    for (var i = 0; i < 4; i++) {
      clients[i].fetch = (_, _) => gates[i].future;
    }
    final future = MusicServerRecommendations.load(clients.map((client) => _source(client)));
    expect(clients.take(4).map((client) => client.requests.length), [1, 1, 1, 1]);
    expect(clients.last.requests, isEmpty);
    clients.last.authenticationSessionId = Object();
    for (var i = 0; i < 4; i++) {
      gates[i].complete([hub(id: 'source-$i')]);
    }
    expect((await future).shelves, hasLength(4));
    expect(clients.last.requests, isEmpty);
  });

  test('source, shelf and row budgets preserve fair server order', () async {
    final clients = List.generate(20, (_) => _Client());
    for (var i = 0; i < clients.length; i++) {
      clients[i].fetch = (_, _) async =>
          List.generate(12, (j) => hub(id: '$i:$j', items: List.generate(50, (k) => musicTrack('track-$k'))));
    }
    final result = await MusicServerRecommendations.load(clients.map((client) => _source(client)));
    expect(clients.where((client) => client.requests.isNotEmpty), hasLength(16));
    expect(result.shelves, hasLength(24));
    expect(result.shelves.take(16).map((row) => row.hub.id), List.generate(16, (i) => '$i:0'));
    expect(result.shelves.every((row) => row.hub.items.length == 12), isTrue);
  });

  test('one failed or degraded source keeps healthy previews and reports incomplete loading', () async {
    final broken = _Client(), degraded = _Client(), healthy = _Client();
    var visible = true;
    broken.fetch = (_, _) async => throw StateError('unavailable');
    degraded.fetch = (_, diagnostics) async {
      diagnostics!.recordFailure(StateError('one leg failed'));
      return [hub(id: 'partial')];
    };
    healthy.fetch = (_, _) async => [hub(id: 'healthy')];
    final result = await MusicServerRecommendations.load([
      _source(broken, current: () => visible),
      _source(degraded, current: () => visible),
      _source(healthy),
    ]);
    expect(result.hasFailures, isTrue);
    expect(result.shelves.map((row) => row.hub.id), ['partial', 'healthy']);
    visible = false;
    expect(result.hasFailures, isFalse);
    expect(result.shelves.map((row) => row.hub.id), ['healthy']);
  });

  test('invisible and offline libraries never request recommendations', () async {
    final offline = _Client()..isOfflineMode = true;
    final hidden = _Client();
    final result = await MusicServerRecommendations.load([_source(offline), _source(hidden, current: () => false)]);
    expect(result.shelves, isEmpty);
    expect(result.hasFailures, isFalse);
    expect(offline.requests, isEmpty);
    expect(hidden.requests, isEmpty);
  });

  test('a bounded preview remains immutable when the provider changes its response list', () async {
    final client = _Client(), rows = [musicTrack('one')];
    client.fetch = (_, _) async => [hub(items: rows)];
    final result = await MusicServerRecommendations.load([_source(client)]);
    rows.clear();
    expect(result.shelves.single.hub.items.single.id, 'one');
  });

  test('each library keeps its own recommendations even on the same server', () async {
    final client = _Client();
    client.fetch = (library, _) async => [
      hub(id: 'family', items: [item(library, library)]),
    ];
    final result = await MusicServerRecommendations.load([_source(client, id: 'a'), _source(client, id: 'b')]);
    expect(result.shelves.map((row) => row.hub.items.single.id), ['a', 'b']);
    expect(result.shelves.map((row) => row.source.libraryId), ['a', 'b']);
  });
}
