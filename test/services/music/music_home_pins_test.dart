import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/music/music_home_pins.dart';
import 'package:plezy/services/music/music_library_store.dart';

import '../../test_helpers/music_experience_fakes.dart';

class _Client extends ExperienceClient {
  MediaItem remote = musicTrack('a');
  Future<MediaItem?> Function(String)? fetch;
  @override
  Future<MediaItem?> fetchItem(String id) async => fetch == null ? remote : await fetch!(id);
}

void main() {
  late AppDatabase database;
  late MusicLibraryStore store;
  late _Client client;
  late MusicHomePins pins;
  var visible = true;
  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    store = MusicLibraryStore(database, 'profile');
    client = _Client();
    visible = true;
    pins = MusicHomePins(store: store, clientFor: (_) => client, visible: (_) => visible);
  });
  tearDown(() async {
    pins.dispose();
    await database.close();
  });

  test('fresh authorized metadata is saved without server payloads or URLs', () async {
    client.remote = musicTrack('a').copyWith(
      title: 'Fresh title',
      thumbPath: 'https://private.example/secret?X-Plex-Token=token',
      raw: {'token': 'secret'},
    );
    final pin = await pins.save(musicTrack('a').copyWith(title: 'Stale title'));
    final json = (await store.documents('homePin')).single;
    expect(pin.item.title, 'Fresh title');
    expect(json.keys.toSet(), {
      'version',
      'id',
      'account',
      'mediaId',
      'server',
      'library',
      'backend',
      'kind',
      'title',
      'order',
    });
    expect(jsonEncode(json), isNot(contains('secret')));
    expect(jsonEncode(json), isNot(contains('https:')));
    expect((await pins.load()).single.item.title, 'Fresh title');
    expect((await pins.resolve(pin)).title, 'Fresh title');
  });

  test('pin updates preserve ordering; remove and reorder use exact visible selection', () async {
    final a = await pins.save(musicTrack('a'));
    client.remote = musicTrack('b');
    final b = await pins.save(musicTrack('b'));
    await pins.reorder([b, a]);
    expect((await pins.load()).map((p) => p.item.id), ['b', 'a']);
    client.remote = musicTrack('a').copyWith(title: 'Updated');
    final updated = await pins.save(musicTrack('a'));
    expect(updated.order, 1);
    await expectLater(pins.reorder([a]), throwsStateError);
    await expectLater(pins.reorder([a, a]), throwsStateError);
    expect((await pins.load()).map((p) => p.item.id), ['b', 'a']);
    await pins.remove(b);
    expect((await pins.load()).single.item.title, 'Updated');
  });

  test('account switch on the same server hides and fences the old references', () async {
    final old = await pins.save(musicTrack('a'));
    client.scopedServerId = 's/other-user';
    expect(await pins.load(), isEmpty);
    await expectLater(pins.remove(old), throwsStateError);
    await expectLater(pins.resolve(old), throwsStateError);
    await pins.save(musicTrack('a'));
    expect(await store.documents('homePin'), hasLength(2));
    client.scopedServerId = 's/user';
    expect((await pins.load()).single.id, old.id);
  });

  test('retiring authentication while metadata is in flight prevents a write', () async {
    final fetched = Completer<MediaItem?>();
    final entered = Completer<void>();
    client.fetch = (_) {
      entered.complete();
      return fetched.future;
    };
    final save = pins.save(musicTrack('a'));
    final assertion = expectLater(save, throwsStateError);
    await entered.future;
    client.authenticationSessionId = Object();
    fetched.complete(musicTrack('a'));
    await assertion;
    expect(await store.documents('homePin'), isEmpty);
  });

  test('hiding a library while metadata loads prevents save and navigation', () async {
    final pin = await pins.save(musicTrack('a'));
    final fetched = Completer<MediaItem?>();
    final entered = Completer<void>();
    client.fetch = (_) {
      entered.complete();
      return fetched.future;
    };
    final navigation = pins.resolve(pin);
    final assertion = expectLater(navigation, throwsStateError);
    await entered.future;
    visible = false;
    fetched.complete(musicTrack('a'));
    await assertion;
    expect(await pins.load(), isEmpty);
    await expectLater(pins.save(musicTrack('a')), throwsStateError);
    expect(await store.documents('homePin'), hasLength(1));
  });

  test('moved or substituted metadata cannot redirect a stored pin', () async {
    final pin = await pins.save(musicTrack('a'));
    client.remote = musicTrack('a').copyWith(libraryId: 'another-library');
    await expectLater(pins.resolve(pin), throwsStateError);
    client.remote = musicTrack('different');
    await expectLater(pins.save(musicTrack('a')), throwsStateError);
    client.remote = musicTrack('a', server: 'other');
    await expectLater(pins.save(musicTrack('a')), throwsStateError);
    expect(await store.documents('homePin'), hasLength(1));
  });

  test('profile deletion cannot resurrect pins from a late fetch', () async {
    final fetched = Completer<MediaItem?>();
    final entered = Completer<void>();
    client.fetch = (_) {
      entered.complete();
      return fetched.future;
    };
    final save = pins.save(musicTrack('a'));
    final assertion = expectLater(save, throwsStateError);
    await entered.future;
    await database.deleteMusicRecipesForProfile('profile');
    fetched.complete(musicTrack('a'));
    await assertion;
    expect(await MusicLibraryStore(database, 'profile').documents('homePin'), isEmpty);
    expect(await pins.load(), isEmpty);
  });

  test('forged ids cannot delete an existing pin', () async {
    final pin = await pins.save(musicTrack('a'));
    final forged = MusicHomePin(id: pin.id, account: pin.account, item: musicTrack('b'), order: 0);
    expect(forged.toJson, throwsFormatException);
    await expectLater(pins.remove(forged), throwsStateError);
    await expectLater(pins.reorder([forged]), throwsStateError);
    expect((await pins.load()).single.id, pin.id);
  });

  test('reordering never replaces canonical metadata with caller supplied presentation', () async {
    final pin = await pins.save(musicTrack('a'));
    final changed = MusicHomePin(
      id: pin.id,
      account: pin.account,
      item: pin.item.copyWith(title: 'Substituted', libraryId: 'other-library'),
      order: pin.order,
    );
    await pins.reorder([changed]);
    final saved = (await pins.load()).single;
    expect(saved.item.title, 'a');
    expect(saved.item.libraryId, 'library');
  });

  test('malformed documents are skipped and still count against profile storage', () async {
    await database.transaction(() async {
      for (var i = 0; i < MusicHomePins.profileLimit; i++) {
        await store.saveDocument('homePin', 'broken-$i', {'version': 99});
      }
    });
    expect(await pins.load(), isEmpty);
    await expectLater(pins.save(musicTrack('a')), throwsStateError);
    expect(await store.documents('homePin', limit: 500), hasLength(500));
  });

  test('account pin quota is bounded and existing pins remain editable', () async {
    await database.transaction(() async {
      for (var i = 0; i < MusicHomePins.limit; i++) {
        final item = musicTrack('track-$i');
        final pin = MusicHomePin(id: MusicHomePin.key('s/user', item), account: 's/user', item: item, order: i);
        await store.saveDocument('homePin', pin.id, pin.toJson());
      }
    });
    await expectLater(pins.save(musicTrack('a')), throwsStateError);
    client.remote = musicTrack('track-0').copyWith(title: 'Updated');
    await pins.save(musicTrack('track-0'));
    expect(await pins.load(), hasLength(100));
    expect((await pins.load()).first.item.title, 'Updated');
  });

  test('queued mutations are bounded and a failure does not poison subsequent saves', () async {
    pins.dispose();
    final barrier = Completer<void>();
    pins = MusicHomePins(store: store, clientFor: (_) => client, ready: () => barrier.future);
    final pending = [for (var i = 0; i < 32; i++) pins.save(musicTrack('a'))];
    await expectLater(pins.save(musicTrack('a')), throwsStateError);
    barrier.complete();
    await Future.wait(pending);
    client.remote = musicTrack('b');
    await expectLater(pins.save(musicTrack('a')), throwsStateError);
    final pin = await pins.save(musicTrack('b'));
    expect(pin.item.id, 'b');
  });

  test('pins reject unsupported kinds and invalid references', () async {
    expect(() => pins.save(musicTrack('a').copyWith(kind: MediaKind.movie)), throwsStateError);
    final pin = await pins.save(musicTrack('a'));
    expect(() => MusicHomePin.fromJson({...pin.toJson(), 'mediaId': 'https://other/token'}), throwsFormatException);
    expect(() => MusicHomePin.fromJson({...pin.toJson(), 'account': 'different'}), throwsFormatException);
    expect(() => MusicHomePin.fromJson({...pin.toJson(), 'order': -1}), throwsFormatException);
  });
}
