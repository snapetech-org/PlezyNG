import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/music/music_account_scope.dart';
import 'package:plezy/services/music/music_history_exchange.dart';
import 'package:plezy/services/music/music_history_reconciliation.dart';
import 'package:plezy/services/music/music_library_store.dart';

import '../../test_helpers/music_experience_fakes.dart';

class _Client extends ExperienceClient implements MusicHistoryAccountClient {
  @override
  String musicHistoryAccountIdentity = 'server-and-user';
}

void main() {
  late AppDatabase database;
  late MusicLibraryStore store;
  late _Client client;
  late MusicHistoryReconciliation history;
  final started = DateTime.utc(2026, 11, 9);
  String id(int value) => '00000000-0000-4000-8000-${value.toString().padLeft(12, '0')}';
  MusicHistoryEntry event(int value, {int listened = 30000}) => MusicHistoryEntry(
    id: id(value),
    item: musicTrack('same'),
    startedAt: started,
    listenedMs: listened,
    finished: false,
    account: musicHistoryAccountScope(client),
  );

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    store = MusicLibraryStore(database, 'profile');
    client = _Client();
    history = MusicHistoryReconciliation(store: store, clients: () => [client]);
  });
  tearDown(() => database.close());

  test('portable event wire format excludes credentials and rejects unknown fields', () {
    final value = event(1);
    final withSecrets = MusicHistoryEntry(
      id: value.id,
      item: value.item.copyWith(raw: {'token': 'secret'}, thumbPath: 'https://server/image?token=secret'),
      startedAt: started,
      listenedMs: 30000,
      finished: true,
      account: value.account,
    );
    final encoded = musicHistoryToWire(withSecrets);
    expect(jsonEncode(encoded), isNot(contains('secret')));
    expect(musicHistoryFromWire(encoded).item.id, 'same');
    expect(() => musicHistoryFromWire({...encoded, 'token': 'secret'}), throwsFormatException);
    expect(() => musicHistoryFromWire({...encoded, 'listened': -1}), throwsFormatException);
    expect(
      () => musicHistoryFromWire({
        ...encoded,
        'started': DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch,
      }),
      throwsFormatException,
    );
    expect(
      () => musicHistoryFromWire({
        ...encoded,
        'item': {
          ...encoded['item'] as Map,
          'raw': {'token': 'secret'},
        },
      }),
      throwsFormatException,
    );
  });

  test('merge retains original IDs and cumulative maxima across repeated imports', () async {
    expect(await history.merge([event(1)], () => true), isTrue);
    expect(await history.merge([event(1, listened: 60000)], () => true), isTrue);
    expect(await history.merge([event(1, listened: 20000)], () => true), isTrue);
    final page = await history.exportPage(history.accounts, null, () => true);
    expect(page.entries, hasLength(1));
    expect(page.entries.single.id, id(1));
    expect(page.entries.single.listenedMs, 60000);
    expect((await store.historyPage()).entries, hasLength(1));
  });

  test('different accounts cannot merge, and collisions roll back the entire page', () async {
    await history.merge([event(1)], () => true);
    final original = event(1);
    final conflicting = MusicHistoryEntry(
      id: original.id,
      item: musicTrack('different'),
      startedAt: started,
      listenedMs: 50000,
      finished: true,
      account: original.account,
    );
    expect(await history.merge([event(2), conflicting], () => true), isFalse);
    expect((await store.historySyncPage()).entries, hasLength(1));
    final foreign = event(3);
    client.musicHistoryAccountIdentity = 'other-user';
    expect(await history.merge([foreign], () => true), isFalse);
    expect((await history.exportPage({foreign.account!}, null, () => true)).entries, isEmpty);
  });

  test('profile deletion and stale authorization prevent import', () async {
    expect(await history.merge([event(1)], () => false), isFalse);
    await database.deleteMusicRecipesForProfile(store.profileId);
    expect(await history.merge([event(1)], () => true), isFalse);
    expect((await MusicLibraryStore(database, store.profileId).historyPage()).entries, isEmpty);
  });

  test('authenticated exchange pages and merges more than one page without duplicates', () async {
    for (var index = 0; index < 23; index++) {
      final entry = event(index);
      await store.record(
        id: entry.id,
        track: entry.item,
        startedAt: entry.startedAt,
        listenedMs: entry.listenedMs,
        finished: false,
        account: entry.account,
      );
    }
    final target = MusicLibraryStore(database, 'other-device');
    final importing = MusicHistoryReconciliation(store: target, clients: () => [client]);
    late MusicHistoryExchange sender, receiver;
    sender = MusicHistoryExchange(
      allowed: () => true,
      accounts: () => history.accounts,
      exportPage: history.exportPage,
      merge: history.merge,
      send: (data) => receiver.receive(data),
    );
    receiver = MusicHistoryExchange(
      allowed: () => true,
      accounts: () => importing.accounts,
      exportPage: importing.exportPage,
      merge: importing.merge,
      send: (data) => sender.receive(data),
    );
    addTearDown(sender.close);
    addTearDown(receiver.close);
    expect(await receiver.request(), isTrue);
    expect((await target.historyPage()).entries, hasLength(23));
    expect(await receiver.request(), isTrue);
    expect((await target.historyPage()).entries, hasLength(23));
    expect(await Future.wait([sender.request(), receiver.request()]), [true, true]);
  });

  test('reset invalidates an in-flight page merge and stale replies', () async {
    final gate = Completer<bool>();
    late Map<String, dynamic> request;
    bool Function()? valid;
    final exchange = MusicHistoryExchange(
      allowed: () => true,
      accounts: () => history.accounts,
      exportPage: history.exportPage,
      merge: (entries, current) {
        valid = current;
        return gate.future;
      },
      send: (data) => request = data,
    );
    addTearDown(exchange.close);
    final pending = exchange.request();
    exchange.receive({
      'version': 1,
      'op': 'page',
      'request': request['request'],
      'sequence': 0,
      'entries': [musicHistoryToWire(event(1))],
      'cursor': null,
    });
    expect(valid!(), isTrue);
    exchange.reset();
    expect(valid!(), isFalse);
    gate.complete(true);
    expect(await pending, isFalse);
  });

  test('malformed, foreign and non-advancing pages fail instead of looping', () async {
    for (final transform in <Map<String, dynamic> Function(Map<String, dynamic>)>[
      (data) => {...data, 'entries': List.filled(9, musicHistoryToWire(event(1)))},
      (data) => {
        ...data,
        'entries': [
          {...musicHistoryToWire(event(1)), 'account': List.filled(64, 'b').join()},
        ],
      },
      (data) => {
        ...data,
        'cursor': [started.millisecondsSinceEpoch + 1, id(1)],
      },
    ]) {
      late Map<String, dynamic> request;
      final exchange = MusicHistoryExchange(
        allowed: () => true,
        accounts: () => history.accounts,
        exportPage: history.exportPage,
        merge: history.merge,
        send: (data) => request = data,
      );
      final pending = exchange.request();
      exchange.receive(
        transform({
          'version': 1,
          'op': 'page',
          'request': request['request'],
          'sequence': 0,
          'entries': [musicHistoryToWire(event(1))],
          'cursor': null,
        }),
      );
      expect(await pending, isFalse);
      exchange.close();
    }
  });
}
