import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/music/music_driving_routes.dart';
import 'package:plezy/services/music/music_library_store.dart';
import 'package:plezy/services/music/music_system_audio_routes.dart';

import 'music_system_audio_routes_test.dart' show route;

MusicSystemAudioOutput output(String id, {bool bluetooth = true}) => MusicSystemAudioOutput(
  id: id,
  name: 'Selected car',
  type: 'BluetoothA2DPOutput',
  bluetooth: bluetooth,
  channels: 2,
);

class _DelayedStore extends MusicLibraryStore {
  _DelayedStore(super.database, super.profileId);
  final entered = Completer<void>(), release = Completer<void>();
  int writes = 0;
  @override
  Future<void> saveDocument(String kind, String id, Map<String, dynamic> value) async {
    writes++;
    if (writes == 1) {
      entered.complete();
      await release.future;
    }
    return super.saveDocument(kind, id, value);
  }
}

void main() {
  late AppDatabase database;
  setUp(() => database = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => database.close());

  Future<MusicDrivingRoutes> preferences(String profile) async {
    final value = MusicDrivingRoutes(MusicLibraryStore(database, profile));
    addTearDown(value.dispose);
    await value.ready;
    return value;
  }

  test('only explicitly selected Bluetooth IDs in the owning platform/profile match', () async {
    final one = await preferences('one'), two = await preferences('two');
    final snapshot = MusicSystemAudioRoute.fromMessage(route());
    expect(one.matches('ios', snapshot), isFalse);
    await one.select(platform: 'ios', output: output('stable-system-id'), current: () => true);
    expect(one.matches('ios', snapshot), isTrue);
    expect(one.matches('android', snapshot), isFalse);
    expect(two.matches('ios', snapshot), isFalse);
    final nonBluetooth = route()
      ..['outputs'] = [
        {'id': 'stable-system-id', 'name': 'Built-in', 'type': 'Speaker', 'bluetooth': false, 'channels': 2},
      ];
    expect(one.matches('ios', MusicSystemAudioRoute.fromMessage(nonBluetooth)), isFalse);
    final restored = await preferences('one');
    expect(restored.routes.single.name, 'Selected car');
    expect(restored.matches('ios', snapshot), isTrue);
    expect(() => restored.routes.clear(), throwsUnsupportedError);
    await restored.remove(route: restored.routes.single, current: () => true);
    expect((await preferences('one')).routes, isEmpty);
  });

  test('retired callers and non-Bluetooth or ambiguous identities cannot save an automatic trigger', () async {
    final value = await preferences('one');
    await expectLater(value.select(platform: 'ios', output: output('car'), current: () => false), throwsStateError);
    expect(
      () => value.select(platform: 'ios', output: output('speaker', bluetooth: false), current: () => true),
      throwsArgumentError,
    );
    expect(() => value.select(platform: 'ios', output: output(''), current: () => true), throwsFormatException);
    expect(value.routes, isEmpty);
    expect(await value.store.document('driving', 'bluetoothRoutes'), isNull);
  });

  test('queued changes recheck their owner after prior writes settle', () async {
    final store = _DelayedStore(database, 'one');
    final preferences = MusicDrivingRoutes(store);
    addTearDown(preferences.dispose);
    await preferences.ready;
    var current = true;
    final first = preferences.select(platform: 'ios', output: output('first'), current: () => current);
    await store.entered.future;
    final next = preferences.select(platform: 'ios', output: output('second'), current: () => current);
    current = false;
    final refusal = expectLater(next, throwsStateError);
    store.release.complete();
    await first;
    await refusal;
    expect(store.writes, 1);
    expect(preferences.routes, isEmpty);
    final restored = await MusicLibraryStore(database, 'one').document('driving', 'bluetoothRoutes');
    expect(
      (restored!['routes'] as List).single['id'],
      'first',
      reason: 'The submitted write remains in its immutable original profile only',
    );
  });

  for (final invalid in [
    {'version': 2, 'routes': []},
    {'version': 1, 'routes': 'invalid'},
    {
      'version': 1,
      'routes': [
        {'platform': 'ios', 'id': '', 'name': 'Bad'},
      ],
    },
    {
      'version': 1,
      'routes': [
        {'platform': 'ios', 'id': 'duplicate', 'name': 'A'},
        {'platform': 'ios', 'id': 'duplicate', 'name': 'B'},
      ],
    },
  ].indexed) {
    test('corrupt saved routes fail closed and require explicit reset: ${invalid.$1}', () async {
      await MusicLibraryStore(database, 'one').saveDocument('driving', 'bluetoothRoutes', invalid.$2);
      final value = await preferences('one');
      expect(value.available, isFalse);
      expect(value.routes, isEmpty);
      await expectLater(value.select(platform: 'ios', output: output('car'), current: () => true), throwsStateError);
      await value.reset(current: () => true);
      expect(value.available, isTrue);
      await value.select(platform: 'ios', output: output('car'), current: () => true);
      expect(value.routes.single.id, 'car');
    });
  }

  test('the saved set has a bounded number of unique routes', () async {
    final value = await preferences('one');
    for (var i = 0; i < MusicDrivingRoutes.maximum; i++) {
      await value.select(platform: 'ios', output: output('car-$i'), current: () => true);
    }
    await expectLater(value.select(platform: 'ios', output: output('overflow'), current: () => true), throwsStateError);
    await value.select(platform: 'ios', output: output('car-0'), current: () => true);
    expect(value.routes.length, MusicDrivingRoutes.maximum);
  });
}
