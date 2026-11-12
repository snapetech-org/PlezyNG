import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_part.dart';
import 'package:plezy/media/media_version.dart';
import 'package:plezy/services/music/music_station.dart';
import 'package:plezy/utils/media_server_http_client.dart';

import '../../test_helpers/music_experience_fakes.dart';

void main() {
  MusicStation station({bool albums = false, int tracks = 100, int minutes = 0, int storageMiB = 0}) => MusicStation(
    id: 'rule',
    title: 'Station',
    serverId: 's',
    libraryId: 'library',
    albums: albums,
    trackLimit: tracks,
    durationMinutes: minutes,
    storageLimitMiB: storageMiB,
  );
  test('continuous mode defaults off for legacy rules and survives save', () {
    final legacy = station().toJson()..remove('continuous');
    expect(MusicStation.fromJson(legacy).continuous, isFalse);
    legacy['continuous'] = true;
    expect(MusicStation.fromJson(legacy).continuous, isTrue);
    legacy['continuous'] = 'yes';
    expect(() => MusicStation.fromJson(legacy), throwsA(isA<TypeError>()));
  });
  test('station rules retain an immutable filter snapshot', () {
    final values = ['Jazz'],
        filters = [
          LibraryFilter(field: 'genre', values: ['Rock']),
        ];
    filters.add(LibraryFilter(field: 'style', values: values));
    final rule = MusicStation(id: 'r', title: 'Filtered', serverId: 's', libraryId: 'library', filters: filters);
    filters.clear();
    values.clear();
    expect(rule.filters.map((filter) => filter.values.single), ['Rock', 'Jazz']);
    expect(() => rule.filters.clear(), throwsUnsupportedError);
  });
  test('refill reads past already queued pages without weakening the filters', () async {
    final client = ExperienceClient();
    client.page = (query) async => LibraryPage(
      items: List.generate((102 - query.offset).clamp(0, 100), (i) => musicTrack('t${query.offset + i}')),
      totalCount: 102,
      offset: query.offset,
    );
    final tracks = await station(
      tracks: 2,
    ).materialize(client, excludedTrackKeys: {for (var i = 0; i < 100; i++) musicTrack('t$i').globalKey});
    expect(tracks.map((track) => track.id), ['t100', 't101']);
    expect(client.queries.map((query) => query.offset), [0, 100]);
    expect(client.queries.every((query) => query.limit == 100), isTrue);
  });
  test('manual exclusion blocks a complete station album', () async {
    final client = ExperienceClient()
      ..rows = [musicTrack('a').copyWith(kind: MediaKind.album), musicTrack('b').copyWith(kind: MediaKind.album)]
      ..albums = {
        'a': [musicTrack('a1', album: 'a'), musicTrack('a2', album: 'a')],
        'b': [musicTrack('b1', album: 'b'), musicTrack('b2', album: 'b')],
      };
    final tracks = await station(
      albums: true,
    ).materialize(client, excludedTrackKeys: {musicTrack('a1', album: 'a').globalKey});
    expect(tracks.map((track) => track.id), ['b1', 'b2']);
  });
  test('station previews retain their exact rule and original account', () async {
    final client = ExperienceClient()..rows = [musicTrack('a')];
    var active = true;
    final rule = station();
    final batch = await rule.preview(client, current: () => active);
    expect(batch.matches(rule), isTrue);
    expect(batch.matches(station(tracks: 2)), isFalse);
    expect(batch.isCurrent(), isTrue);
    active = false;
    expect(batch.isCurrent(), isFalse);
  });
  test('a profile retirement during a station page rejects the batch', () async {
    final client = ExperienceClient();
    var active = true;
    final pending = Completer<LibraryPage<MediaItem>>();
    client.page = (_) => pending.future;
    final result = station().preview(client, current: () => active);
    final rejected = expectLater(result, throwsStateError);
    active = false;
    pending.complete(LibraryPage(items: [musicTrack('a')], totalCount: 1));
    await rejected;
  });
  test('time and count budgets stop generation without splitting album blocks', () async {
    final client = ExperienceClient()
      ..rows = [
        musicTrack('large').copyWith(kind: MediaKind.album),
        musicTrack('small').copyWith(kind: MediaKind.album),
      ];
    client.albums = {
      'large': [musicTrack('1', album: 'large'), musicTrack('2', album: 'large'), musicTrack('3', album: 'large')],
      'small': [musicTrack('b2', album: 'small', index: 2), musicTrack('b1', album: 'small', index: 1)],
    };
    final items = await station(albums: true, tracks: 2, minutes: 2).materialize(client);
    expect(items.map((t) => t.id), ['b1', 'b2']);
  });
  test('an invalid album block never contributes its otherwise valid tracks', () async {
    final client = ExperienceClient()
      ..rows = [
        musicTrack('foreign-child').copyWith(kind: MediaKind.album),
        musicTrack('wrong-album').copyWith(kind: MediaKind.album),
        musicTrack('duplicate').copyWith(kind: MediaKind.album),
        musicTrack('valid').copyWith(kind: MediaKind.album),
      ];
    final repeated = musicTrack('repeated', album: 'duplicate');
    client.albums = {
      'foreign-child': [
        musicTrack('a', album: 'foreign-child'),
        musicTrack('b', server: 'other', album: 'foreign-child'),
      ],
      'wrong-album': [musicTrack('c', album: 'wrong-album'), musicTrack('d', album: 'different')],
      'duplicate': [repeated, repeated],
      'valid': [musicTrack('end', album: 'valid', disc: 2), musicTrack('start', album: 'valid')],
    };
    final items = await station(albums: true).materialize(client);
    expect(items.map((track) => track.id), ['start', 'end']);
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
  test('station materialization rejects foreign and missing library identities', () async {
    final client = ExperienceClient()
      ..rows = [
        musicTrack('foreign').copyWith(libraryId: 'other'),
        musicTrack('missing').copyWith(libraryId: null),
        musicTrack('valid'),
      ];
    expect((await station().materialize(client)).map((track) => track.id), ['valid']);
    expect(station().acceptsBatch([musicTrack('foreign').copyWith(libraryId: 'other')]), isFalse);
    expect(station().acceptsBatch([musicTrack('duplicate'), musicTrack('duplicate')]), isFalse);
    expect(station(minutes: 1).acceptsBatch([musicTrack('long', durationMs: 120000)]), isFalse);
  });
  test('storage estimates use complete source parts, then bitrate, then duration', () {
    final exact = musicTrack('exact').copyWith(
      mediaVersions: [
        const MediaVersion(
          id: 'version',
          parts: [
            MediaPart(id: 'one', sizeBytes: 100),
            MediaPart(id: 'two', sizeBytes: 200),
          ],
        ),
      ],
    );
    expect(musicTrackEstimatedBytes(exact), 300);
    final bitrate = musicTrack(
      'bitrate',
      durationMs: 1000,
    ).copyWith(mediaVersions: [const MediaVersion(id: 'version', bitrate: 320)]);
    expect(musicTrackEstimatedBytes(bitrate), 40000);
    expect(musicTrackEstimatedBytes(musicTrack('fallback', durationMs: 1000)), 192000);
    expect(musicTrackEstimatedBytes(musicTrack('unknown', durationMs: null)), isNull);
  });
  test('storage budgets skip large tracks and preserve album blocks', () async {
    final large = musicTrack('large').copyWith(
      mediaVersions: [
        const MediaVersion(
          id: 'v',
          parts: [MediaPart(id: 'p', sizeBytes: 2000000)],
        ),
      ],
    );
    final small = musicTrack('small', durationMs: 1000);
    final client = ExperienceClient()..rows = [large, small, musicTrack('unknown', durationMs: null)];
    expect((await station(storageMiB: 1).materialize(client)).map((track) => track.id), ['small']);
    client.rows = [musicTrack('album').copyWith(kind: MediaKind.album)];
    client.albums = {
      'album': [small, large],
    };
    expect(await station(storageMiB: 1, albums: true).materialize(client), isEmpty);
  });
  test('retry estimates are required to be positive and fit the remaining budget', () {
    final rule = station(storageMiB: 1);
    final track = musicTrack('short', durationMs: 1000);
    expect(rule.acceptsBatch([track], estimatedBytes: {track.globalKey: 2000000}), isFalse);
    expect(rule.acceptsBatch([track], estimatedBytes: {track.globalKey: -1}), isFalse);
    expect(rule.acceptsBatch([track], estimatedBytes: {}), isFalse);
    expect(rule.acceptsBatch([track], storageBudgetBytes: 0, alreadyOwned: {track.globalKey}), isTrue);
    final legacy = rule.toJson()..remove('storageLimitMiB');
    expect(MusicStation.fromJson(legacy).storageLimitMiB, 0);
    expect(() => station(storageMiB: -1), throwsArgumentError);
  });
}
