import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/seerr/seerr_session.dart';
import 'package:plezy/models/seerr/seerr_details.dart';
import 'package:plezy/models/seerr/seerr_media.dart';
import 'package:plezy/models/seerr/seerr_public_settings.dart';
import 'package:plezy/models/seerr/seerr_request.dart';
import 'package:plezy/models/seerr/seerr_request_intent.dart';
import 'package:plezy/services/catalog/seerr_catalog_source.dart';
import 'package:plezy/services/seerr/seerr_client.dart';
import 'package:plezy/services/seerr/seerr_constants.dart';
import 'package:plezy/widgets/seerr_title_action.dart';

SeerrClient _client(MockClient mock, {int permissions = SeerrPermission.request}) {
  final client = SeerrClient(
    SeerrSession(
      baseUrl: 'https://seerr.example.com',
      method: SeerrAuthMethod.local,
      identifier: 'alice',
      secret: 'pw',
      cookie: 'session',
      userId: 7,
      permissions: permissions,
      displayName: 'Alice',
      instanceLabel: 'Seerr',
      createdAt: 0,
    ),
    onSessionInvalidated: () {},
    httpClient: mock,
  );
  addTearDown(client.dispose);
  return client;
}

http.Response _answer(List<Map<String, Object?>> states, {int status = 200}) =>
    http.Response(jsonEncode({'items': states}), status, headers: {'content-type': 'application/json'});

Map<String, Object?> _state(
  String type,
  int id, {
  String? own,
  String? other,
  bool canSubscribe = false,
  bool quickRequest = false,
}) => {
  'mediaType': type,
  'tmdbId': id,
  'status': 2,
  'status4k': 1,
  'standard': {'own': own, 'other': other},
  'fourK': {'own': null, 'other': null},
  'canSubscribe': canSubscribe,
  'subscribed': false,
  'canRequest': true,
  'canRequest4k': false,
  'quickRequest': quickRequest,
  'seasons': <Object>[],
};

void main() {
  test('an aired TV season absent from stored coverage offers a missing-season action', () {
    final state = SeerrRequestIntent.fromJson(_state('tv', 42));
    final details = SeerrDetails(
      seasons: [
        const SeerrSeason(seasonNumber: 0, episodeCount: 1, airDate: '2020-01-01'),
        const SeerrSeason(seasonNumber: 2, episodeCount: 8, airDate: '2026-10-01'),
        const SeerrSeason(seasonNumber: 3, episodeCount: 8, airDate: '2027-01-01'),
      ],
    );
    expect(hasNewSeerrSeason(state, details, now: DateTime.utc(2026, 11, 9)), isTrue);
    final claimed = SeerrRequestIntent.fromJson(_state('tv', 42, own: 'pending'));
    expect(hasNewSeerrSeason(claimed, details, now: DateTime.utc(2026, 11, 9)), isTrue);
  });

  test('a playable show can offer its independent 4K variant', () {
    final client = _client(MockClient((_) async => _answer([])), permissions: SeerrPermission.request4kTv);
    final json = _state('tv', 42)..['canRequest4k'] = true;
    final state = SeerrRequestIntent.fromJson(json);
    expect(
      librarySeerrTitleAction(SeerrCatalogSource(client), MediaKind.show, state)?.kind,
      SeerrTitleActionKind.request4k,
    );
  });

  test('plain Seerr offers a library 4K request only while the quality is open and enabled', () {
    final client = _client(MockClient((_) async => _answer([])), permissions: SeerrPermission.request4kMovie);
    final source = SeerrCatalogSource(client);
    const enabled = SeerrPublicSettings(movie4kEnabled: true);
    const disabled = SeerrPublicSettings();
    const open = SeerrDetails(mediaInfo: SeerrMediaInfo(statusCode: 5, status4kCode: 1));
    SeerrLegacyLibraryOpportunity opportunity(SeerrDetails details, SeerrPublicSettings settings) =>
        SeerrLegacyLibraryOpportunity.fromDetails(source, MediaKind.movie, details, settings);

    expect(opportunity(open, enabled).request4k, isTrue);
    expect(opportunity(const SeerrDetails(), enabled).request4k, isTrue);
    expect(opportunity(open, disabled).request4k, isFalse);
    expect(opportunity(const SeerrDetails(mediaInfo: SeerrMediaInfo(status4kCode: 5)), enabled).request4k, isFalse);
    expect(opportunity(const SeerrDetails(mediaInfo: SeerrMediaInfo(status4kCode: 2)), enabled).request4k, isFalse);
    expect(
      opportunity(
        const SeerrDetails(
          mediaInfo: SeerrMediaInfo(requests: [SeerrRequest(id: 1, status: SeerrRequestStatus.approved, is4k: true)]),
        ),
        enabled,
      ).request4k,
      isFalse,
    );
  });

  test('plain Seerr offers only aired, unclaimed missing library seasons', () {
    final client = _client(MockClient((_) async => _answer([])));
    final source = SeerrCatalogSource(client);
    const seasons = [
      SeerrSeason(seasonNumber: 0, episodeCount: 1, airDate: '2020-01-01'),
      SeerrSeason(seasonNumber: 2, episodeCount: 8, airDate: '2026-10-01'),
      SeerrSeason(seasonNumber: 3, episodeCount: 8, airDate: '2027-01-01'),
    ];
    SeerrLegacyLibraryOpportunity opportunity(SeerrMediaInfo? info) => SeerrLegacyLibraryOpportunity.fromDetails(
      source,
      MediaKind.show,
      SeerrDetails(seasons: seasons, mediaInfo: info),
      const SeerrPublicSettings(),
      now: DateTime.utc(2026, 11, 9),
    );

    expect(opportunity(const SeerrMediaInfo(statusCode: 4)).missingSeasons, isTrue);
    expect(opportunity(null).missingSeasons, isFalse);
    expect(opportunity(const SeerrMediaInfo(statusCode: 5)).missingSeasons, isFalse);
    expect(
      opportunity(const SeerrMediaInfo(seasons: [SeerrSeasonInfo(seasonNumber: 2, statusCode: 5)])).missingSeasons,
      isFalse,
    );
    expect(
      opportunity(const SeerrMediaInfo(seasons: [SeerrSeasonInfo(seasonNumber: 2, statusCode: 6)])).missingSeasons,
      isFalse,
    );
    expect(
      opportunity(
        const SeerrMediaInfo(
          requests: [
            SeerrRequest(id: 1, status: SeerrRequestStatus.pending, seasons: [SeerrRequestSeason(seasonNumber: 2)]),
          ],
        ),
      ).missingSeasons,
      isFalse,
    );
    expect(
      librarySeerrTitleActions(
        source,
        MediaKind.show,
        null,
        legacy: opportunity(const SeerrMediaInfo(statusCode: 4)),
      ).single.kind,
      SeerrTitleActionKind.requestSeasons,
    );
  });

  test('a 4K-only viewer gets the 4K request sheet on vanilla Seerr', () {
    final client = _client(MockClient((_) async => _answer([])), permissions: SeerrPermission.request4kMovie);
    final action = seerrTitleAction(SeerrCatalogSource(client), MediaKind.movie, null);
    expect(action?.kind, SeerrTitleActionKind.request4k);
    expect(seerrTitleActions(SeerrCatalogSource(client), MediaKind.movie, null), hasLength(1));
  });

  test('requesting missing seasons does not hide an existing alert switch', () {
    final client = _client(MockClient((_) async => _answer([])));
    final json = _state('tv', 42)
      ..['subscribed'] = true
      ..['subscriptionScope'] = {'is4k': false, 'seasonNumber': null}
      ..['seasons'] = [
        {
          'seasonNumber': 2,
          'status': 1,
          'standard': {'own': null, 'other': null},
        },
      ];
    final state = SeerrRequestIntent.fromJson(json);
    expect(seerrTitleActions(SeerrCatalogSource(client), MediaKind.show, state).map((action) => action.kind), [
      SeerrTitleActionKind.requestSeasons,
      SeerrTitleActionKind.notificationsOn,
    ]);
    expect(librarySeerrTitleActions(SeerrCatalogSource(client), MediaKind.show, state).map((action) => action.kind), [
      SeerrTitleActionKind.requestSeasons,
      SeerrTitleActionKind.notificationsOn,
    ]);
  });

  test('a subscribed 4K viewer can still request the standard copy', () {
    final client = _client(MockClient((_) async => _answer([])));
    final json = _state('movie', 42)
      ..['status4k'] = 5
      ..['subscribed'] = true
      ..['subscriptionScope'] = {'is4k': true, 'seasonNumber': null};
    final state = SeerrRequestIntent.fromJson(json);
    expect(seerrTitleActions(SeerrCatalogSource(client), MediaKind.movie, state).map((action) => action.kind), [
      SeerrTitleActionKind.request,
      SeerrTitleActionKind.notificationsOn,
    ]);
  });

  test('a standard request does not prevent requesting the independent 4K copy', () {
    final client = _client(
      MockClient((_) async => _answer([])),
      permissions: SeerrPermission.request | SeerrPermission.request4kMovie,
    );
    final json = _state('movie', 42, own: 'pending')..['canRequest4k'] = true;
    final state = SeerrRequestIntent.fromJson(json);
    expect(seerrTitleAction(SeerrCatalogSource(client), MediaKind.movie, state)?.kind, SeerrTitleActionKind.request4k);
  });

  test('a library alert is not silently replaced by a different 4K alert', () {
    final client = _client(MockClient((_) async => _answer([])));
    final json = _state('movie', 42)
      ..['subscribed'] = true
      ..['subscriptionScope'] = {'is4k': false, 'seasonNumber': null}
      ..['fourK'] = {'own': null, 'other': 'approved'}
      ..['canSubscribe4k'] = true;
    final state = SeerrRequestIntent.fromJson(json);
    expect(librarySeerrTitleActions(SeerrCatalogSource(client), MediaKind.movie, state).map((action) => action.kind), [
      SeerrTitleActionKind.notificationsOn,
    ]);
  });

  test('a viewer without request rights can follow another request', () {
    final client = _client(MockClient((_) async => _answer([])), permissions: 0);
    final state = SeerrRequestIntent.fromJson(_state('movie', 42, other: 'approved', canSubscribe: true));
    expect(seerrTitleAction(SeerrCatalogSource(client), MediaKind.movie, state)?.kind, SeerrTitleActionKind.notify);
    expect(seerrTitleAction(SeerrCatalogSource(client), MediaKind.movie, null), isNull);
  });

  testWidgets('a simple movie request takes one action and carries a stable replay key', (tester) async {
    final keys = <String?>[];
    final client = _client(
      MockClient((request) async {
        if (request.url.path.endsWith('/request/intent/state')) {
          return _answer([_state('movie', 88, quickRequest: true)]);
        }
        if (request.url.path.endsWith('/request')) {
          keys.add(request.headers['Idempotency-Key']);
          return http.Response(jsonEncode({'id': 17, 'status': 1}), 201, headers: {'content-type': 'application/json'});
        }
        fail('Unexpected ${request.url.path}');
      }),
    );
    await tester.runAsync(() => client.intents.load(MediaKind.movie, 88));
    final source = SeerrCatalogSource(client);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => performSeerrTitleAction(
                context,
                source: source,
                kind: MediaKind.movie,
                tmdbId: 88,
                title: 'Movie',
                action: const SeerrTitleAction(SeerrTitleActionKind.request),
              ),
              child: const Text('Request'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Request'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(keys, hasLength(1));
    expect(keys.single, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(find.text('Request submitted'), findsOneWidget);
    expect(find.text('Seasons'), findsNothing);
  });

  test('a notification subscription sends the exact requested scope', () async {
    Map<String, dynamic>? body;
    final client = _client(
      MockClient((request) async {
        if (request.url.path.endsWith('/availability-subscriptions/tv/8')) {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return _answer([]);
        }
        if (request.url.path.endsWith('/request/intent/state')) return _answer([_state('tv', 8)]);
        fail('Unexpected ${request.url.path}');
      }),
    );
    await client.subscribeToAvailability(MediaKind.show, 8, is4k: false, seasonNumber: 3);
    expect(body, {'is4k': false, 'seasonNumber': 3});
  });
  test('coalesces cards and keeps overlapping movie/TV ids separate', () async {
    final sent = <List<dynamic>>[];
    final client = _client(
      MockClient((request) async {
        sent.add((jsonDecode(request.body) as Map<String, dynamic>)['items'] as List<dynamic>);
        return _answer([_state('movie', 42, other: 'approved', canSubscribe: true), _state('tv', 42, own: 'pending')]);
      }),
    );
    await Future.wait([client.intents.load(MediaKind.movie, 42), client.intents.load(MediaKind.show, 42)]);
    expect(sent, hasLength(1));
    expect(sent.single, hasLength(2));
    expect(client.intents.peek(MediaKind.movie, 42)?.other, 'approved');
    expect(client.intents.peek(MediaKind.show, 42)?.own, 'pending');
    expect(
      seerrTitleAction(SeerrCatalogSource(client), MediaKind.movie, client.intents.peek(MediaKind.movie, 42))?.kind,
      SeerrTitleActionKind.notify,
    );
  });

  test('an invalidated in-flight answer cannot overwrite a fresh mutation', () async {
    final old = Completer<http.Response>();
    var calls = 0;
    final client = _client(
      MockClient((request) async {
        calls++;
        return calls == 1 ? old.future : _answer([_state('movie', 5, own: 'approved')]);
      }),
    );
    final pending = client.intents.load(MediaKind.movie, 5);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    client.intents.invalidate(MediaKind.movie, 5);
    old.complete(_answer([_state('movie', 5, other: 'pending')]));
    await pending;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(calls, 2);
    expect(client.intents.peek(MediaKind.movie, 5)?.own, 'approved');
  });

  test('an older Seerr without the endpoint quietly retains the request sheet', () async {
    var calls = 0;
    final client = _client(
      MockClient((_) async {
        calls++;
        return http.Response(
          jsonEncode({'status': 404, 'message': 'Not found'}),
          404,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await client.intents.load(MediaKind.movie, 11);
    await client.intents.load(MediaKind.movie, 11);
    expect(calls, 1);
    expect(seerrTitleAction(SeerrCatalogSource(client), MediaKind.movie, null)?.kind, SeerrTitleActionKind.request);
  });
}
