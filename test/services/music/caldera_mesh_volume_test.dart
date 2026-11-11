import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/caldera_mesh_volume.dart';

void main() {
  test('bounded finite volume only; no extra control authority', () async {
    var volume = 50.0, changes = 0;
    final commands = CalderaMeshVolume(write: (value) async => volume = value, read: () => volume);
    for (final payload in [
      null,
      {},
      {'volume': '37'},
      {'volume': double.nan},
      {'volume': double.infinity},
      {'volume': -1},
      {'volume': 101},
      {'volume': 37, 'source': 'other'},
    ]) {
      expect(() => commands.apply(payload, current: () => true, changed: () => changes++), throwsFormatException);
    }
    await commands.apply({'volume': 37}, current: () => true, changed: () => changes++);
    expect(volume, 37);
    expect(changes, 1);
    expect(commands.state('source')['volume'], 37);
  });

  test('serialized writes recheck each queued connection and account scope', () async {
    final gate = Completer<void>(), writes = <double>[];
    var current = true, changes = 0;
    final commands = CalderaMeshVolume(
      write: (value) async {
        writes.add(value);
        await gate.future;
      },
      read: () => 50,
    );
    final first = commands.apply({'volume': 30}, current: () => current, changed: () => changes++);
    final second = commands.apply({'volume': 40}, current: () => current, changed: () => changes++);
    final failure = expectLater(second, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(writes, [30]);
    current = false;
    gate.complete();
    await first;
    await failure;
    expect(writes, [30]);
    expect(changes, 0);
  });

  test('32 pending writes bound native traffic and failure does not poison the queue', () async {
    final gate = Completer<void>();
    var fail = true;
    final commands = CalderaMeshVolume(
      write: (value) async {
        await gate.future;
        if (fail) throw StateError('native failed');
      },
      read: () => 50,
    );
    final checks = <Future<void>>[];
    for (var i = 0; i < 32; i++) {
      checks.add(expectLater(commands.apply({'volume': i}, current: () => true, changed: () {}), throwsStateError));
    }
    expect(() => commands.apply({'volume': 70}, current: () => true, changed: () {}), throwsStateError);
    gate.complete();
    await Future.wait(checks);
    fail = false;
    await commands.apply({'volume': 70}, current: () => true, changed: () {});
  });
}
