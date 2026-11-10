import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/music/music_station.dart';
import 'package:plezy/utils/media_server_http_client.dart';

import '../../test_helpers/music_experience_fakes.dart';

void main() {
  MusicStation station({bool albums = false, int tracks = 100, int minutes = 0}) => MusicStation(
    id: 'rule',
    title: 'Station',
    serverId: 's',
    libraryId: 'library',
    albums: albums,
    trackLimit: tracks,
    durationMinutes: minutes,
  );
  test('time and count budgets stop generation without splitting album blocks', () async {
    final client = ExperienceClient()
      ..rows = [
        musicTrack('large').copyWith(kind: MediaKind.album),
        musicTrack('small').copyWith(kind: MediaKind.album),
      ];
    client.albums = {
      'large': [musicTrack('1'), musicTrack('2'), musicTrack('3')],
      'small': [musicTrack('b2', index: 2), musicTrack('b1', index: 1)],
    };
    final items = await station(albums: true, tracks: 2, minutes: 2).materialize(client);
    expect(items.map((t) => t.id), ['b1', 'b2']);
  });
  test('time-budgeted stations exclude unknown duration and foreign servers', () async {
    final client = ExperienceClient()
      ..rows = [
        musicTrack('unknown', durationMs: null),
        musicTrack('foreign', server: 'other'),
        musicTrack('a'),
        musicTrack('b'),
        musicTrack('c'),
      ];
    expect((await station(minutes: 2).materialize(client)).map((t) => t.id), ['a', 'b']);
  });
  test('an oversized first track does not hide later fitting tracks', () async {
    final client = ExperienceClient()
      ..rows = [musicTrack('long', durationMs: 180000), musicTrack('short', durationMs: 60000)];
    expect((await station(minutes: 1).materialize(client)).map((t) => t.id), ['short']);
  });
  test('providers that repeat random pages terminate with unique tracks', () async {
    final client = ExperienceClient()
      ..page = (_) async => LibraryPage(items: [musicTrack('a'), musicTrack('b')], totalCount: 1000);
    expect(await station().materialize(client), hasLength(2));
    expect(client.queries, hasLength(2));
  });
  test('cancellation rejects late page results', () async {
    final abort = AbortController();
    final client = ExperienceClient()
      ..page = (_) async {
        abort.abort();
        return LibraryPage(items: [musicTrack('a')], totalCount: 1);
      };
    await expectLater(station().materialize(client, abort: abort), throwsA(isA<Exception>()));
  });
  test('future filter operators are rejected instead of silently widening a rule', () {
    final json = station().toJson();
    json['filters'] = [
      {
        'field': 'genre',
        'op': 'unknownOperator',
        'values': ['private'],
      },
    ];
    expect(() => MusicStation.fromJson(json), throwsFormatException);
  });
  test('saved rules round trip limits and album mode', () {
    final rule = station(albums: true, tracks: 250, minutes: 360);
    expect(MusicStation.fromJson(rule.toJson()).toJson(), rule.toJson());
    expect(() => station(tracks: 5001), throwsArgumentError);
  });
  test('authorization changes between station pages cancel the whole snapshot', () async {
    final client = ExperienceClient();
    client.page = (_) async {
      client.authenticationSessionId = Object();
      return LibraryPage(items: [musicTrack('a')], totalCount: 1);
    };
    await expectLater(station().materialize(client), throwsStateError);
  });
}
