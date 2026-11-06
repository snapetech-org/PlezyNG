import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/extras/extras_ai.dart';
import 'package:plezy/extras/extras_models.dart';
import 'package:plezy/extras/extras_repository.dart';
import 'package:plezy/extras/extras_session.dart';
import 'package:plezy/extras/extras_store.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import '../test_helpers/prefs.dart';

const subject = ExtrasSubject(
  key: 'movie/tmdb:120',
  identities: {'movie/tmdb:120'},
  title: 'Fellowship',
  watched: true,
);
ExtraEntry candidate({String id = '12345678901', bool permitted = false}) => ExtraEntry(
  id: id,
  title: 'Prosthetics',
  parentIdentities: subject.allIdentities,
  kind: ExtraKind.makeup,
  origin: ExtraOrigin.catalog,
  url: Uri.https('www.youtube.com', '/watch', {'v': id}),
  verifiedPublisher: true,
  catalogAssociated: true,
  analysisAllowed: permitted,
  passages: const [ExtraPassage(startSeconds: 12, endSeconds: 18, text: 'The prosthetics were painted by hand.')],
);

void main() {
  setUp(resetSharedPreferencesForTest);

  test('profile secrets are encrypted, isolated and removed with profile data', () async {
    final a = ExtrasStore('a'), b = ExtrasStore('b');
    await a.saveSecrets(discovery: 'discovery-secret', ai: 'ai-secret');
    await a.savePreferences(const ExtrasPreferences(showSpoilers: true));
    expect(await a.secret('ai'), 'ai-secret');
    expect(await b.secret('ai'), '');
    expect((await b.preferences()).showSpoilers, false);
    final prefs = await BaseSharedPreferencesService.sharedCache();
    for (final key in prefs.keys.where((k) => k.endsWith('_extras_credentials_v1'))) {
      expect(prefs.getString(key), isNot(contains('ai-secret')));
    }
    await a.clear();
    expect(await a.secret('ai'), '');
    expect((await a.preferences()).showSpoilers, false);
  });

  test('concurrent writes retain exclusions, transcript and separate progress', () async {
    final store = ExtrasStore('a');
    await Future.wait([
      store.exclude(subject, candidate(), 'wrong'),
      store.recordProgress('extra', seconds: 12),
      store.saveTranscript('extra', candidate().passages),
    ]);
    expect((await store.preferences()).wrongMatches, contains('${subject.key}|12345678901'));
    expect((await store.progress('extra'))['completed'], false);
    expect((await store.transcript('extra'))!.single.startSeconds, 12);
    expect(await ExtrasStore('b').progress('extra'), isEmpty);
    await store.recordProgress('extra'); // A handoff must not mark completion.
    expect((await store.progress('extra'))['seconds'], 12);
    expect((await store.progress('extra'))['completed'], false);
  });

  test('inactive profile cannot write late results or credentials', () async {
    var current = true;
    final store = ExtrasStore('a', isCurrent: () => current);
    current = false;
    await store.savePreferences(const ExtrasPreferences(showSpoilers: true));
    await store.saveSecrets(discovery: 'secret', ai: 'secret');
    expect((await ExtrasStore('a').preferences()).showSpoilers, false);
    expect(await store.secret('ai'), '');
  });

  test('cache is bounded and a hidden result stays hidden on cache hits', () async {
    final store = ExtrasStore('a');
    for (var i = 0; i < 30; i++) {
      await store.saveCache('$i', [candidate()]);
    }
    expect(await store.cache('0'), isNull);
    expect(await store.cache('29'), isNotNull);
    await store.savePreferences(const ExtrasPreferences(serviceUrl: 'https://extras.example/'));
    var calls = 0;
    final repository = ExtrasRepository(
      store,
      client: MockClient((r) async {
        calls++;
        expect(r.followRedirects, false);
        expect(r.url.path, '/v1/discover');
        final request = jsonDecode(r.body) as Map;
        expect(request.containsKey('watched'), false);
        return http.Response(
          jsonEncode({
            'version': 1,
            'entries': [candidate().toJson()],
          }),
          200,
        );
      }),
    );
    addTearDown(repository.close);
    expect((await repository.load(subject)).entries, hasLength(1));
    await store.exclude(subject, candidate(), 'hide');
    expect((await repository.load(subject)).entries, isEmpty);
    expect(calls, 1);
  });

  test('offline and restricted discovery never calls the service', () async {
    final store = ExtrasStore('a');
    await store.savePreferences(const ExtrasPreferences(serviceUrl: 'https://extras.example/'));
    final repo = ExtrasRepository(store, client: MockClient((r) async => throw StateError('must not call')));
    addTearDown(repo.close);
    for (final restricted in [true, false]) {
      final result = await repo.load(
        ExtrasSubject(
          key: subject.key,
          identities: subject.identities,
          title: subject.title,
          restricted: restricted,
          offline: !restricted,
        ),
      );
      expect(result.entries, isEmpty);
      expect(result.serviceUnavailable, false);
    }
  });

  test('malformed response and provider outage degrade to native selection', () async {
    final store = ExtrasStore('a');
    await store.savePreferences(const ExtrasPreferences(serviceUrl: 'https://extras.example/'));
    for (final response in [
      http.Response('no', 500),
      http.Response('[]', 200),
      http.Response('{"version":2,"entries":[]}', 200),
    ]) {
      final repo = ExtrasRepository(store, client: MockClient((_) async => response));
      final local = ExtraEntry(
        id: 'native',
        title: 'Making of',
        parentIdentities: subject.allIdentities,
        origin: ExtraOrigin.library,
        kind: ExtraKind.makingOf,
        nativeKey: 'server:clip',
      );
      final result = await repo.load(subject, library: [local]);
      expect(result.entries.single.id, 'native');
      expect(result.serviceUnavailable, true);
      repo.close();
    }
  });

  test('AI cannot invent passages, URLs or source permissions', () async {
    final blocked = candidate();
    final permitted = candidate(id: 'abcdefghijk', permitted: true);
    final ai = ExtrasAi(
      client: MockClient((r) async {
        expect(r.url.path, '/v1/chat/completions');
        expect(r.body, isNot(contains('youtube.com')));
        expect(r.body, isNot(contains('12345678901')));
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'kinds': ['invented'],
                    'url': 'https://bad.example',
                    'passages': [
                      {'id': blocked.id, 'start': 12, 'quote': blocked.passages.single.text},
                      {'id': permitted.id, 'start': 999, 'quote': permitted.passages.single.text},
                      {'id': permitted.id, 'start': 12, 'quote': 'Invented'},
                      {'id': permitted.id, 'start': 12, 'quote': permitted.passages.single.text},
                    ],
                  }),
                },
              },
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(ai.close);
    final answer = await ai.search('skin', [
      blocked,
      permitted,
    ], const ExtrasPreferences(aiMode: ExtrasAiMode.server, aiUrl: 'https://model.example/v1', aiModel: 'local'));
    expect(answer.kinds, isEmpty);
    expect(answer.passages.keys, [permitted.id]);
    expect(answer.passages[permitted.id]!.single.startSeconds, 12);
    expect(blocked.withPassages(blocked.passages).analysisAllowed, false);
    expect(blocked.withPassages(blocked.passages, userSupplied: true).analysisAllowed, true);
  });

  test('inference failure retains deterministic transcript matches', () async {
    final ai = ExtrasAi(client: MockClient((_) async => http.Response('broken', 200)));
    addTearDown(ai.close);
    final answer = await ai.search('painted', [
      candidate(permitted: true),
    ], const ExtrasPreferences(aiMode: ExtrasAiMode.server, aiUrl: 'http://127.0.0.1:11434/v1', aiModel: 'local'));
    expect(answer.usedAi, false);
    expect(answer.passages.values.single.single.startSeconds, 12);
  });

  test('endpoint validation constrains device mode and rejects URL credentials', () {
    expect(extrasServiceUri('https://secret@example.com'), isNull);
    expect(extrasServiceUri('http://example.com'), isNull);
    expect(extrasServiceUri('http://192.168.1.2:8792'), isNotNull);
    expect(extrasServiceUri('https://example.com', deviceOnly: true), isNull);
    expect(extrasServiceUri('http://[::1]:1234/v1', deviceOnly: true)?.path, '/v1/');
  });

  test('disposed sessions never publish a late request result', () async {
    final store = ExtrasStore('a');
    await store.savePreferences(const ExtrasPreferences(serviceUrl: 'https://extras.example/'));
    final response = Completer<http.Response>(), started = Completer<void>();
    final repo = ExtrasRepository(
      store,
      client: MockClient((_) {
        started.complete();
        return response.future;
      }),
    );
    final session = ExtrasSession(subject: subject, store: store, repository: repo);
    var notifications = 0;
    session.addListener(() => notifications++);
    final work = session.refresh();
    await started.future;
    session.dispose();
    final before = notifications;
    response.complete(
      http.Response(
        jsonEncode({
          'version': 1,
          'entries': [candidate().toJson()],
        }),
        200,
      ),
    );
    await work;
    expect(notifications, before);
    expect(session.entries, isEmpty);
  });
}
