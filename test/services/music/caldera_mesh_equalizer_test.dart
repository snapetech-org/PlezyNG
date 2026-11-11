import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/caldera_mesh_equalizer.dart';
import '../../test_helpers/fake_caldera_equalizer.dart';

void main() {
  test('native field commands compose at execution and copy mutable input', () async {
    final output = FakeCalderaEqualizer()..gate = Completer<void>();
    final commands = CalderaMeshEqualizer(output);
    var changes = 0;
    final bands = [
      {'filterType': 0, 'frequency': 1000, 'gain': 2, 'q': .7},
    ];
    final pending = [
      commands.apply('SetSinkEqualizerEnabled', {'enabled': true}, current: () => true, changed: () => changes++),
      commands.apply('SetSinkEqualizerGain', {'gain': -3.5}, current: () => true, changed: () => changes++),
      commands.apply('SetSinkEqualizerBands', {'bands': bands}, current: () => true, changed: () => changes++),
    ];
    bands.clear();
    output.gate!.complete();
    await Future.wait(pending);
    expect(output.calderaEqualizer.enabled, isTrue);
    expect(output.calderaEqualizer.gain, -3.5);
    expect(output.calderaEqualizer.bands.single.frequency, 1000);
    expect(changes, 3);
    final data = CalderaMeshEqualizer.snapshot(output.calderaEqualizer);
    expect(CalderaMeshEqualizer.restore(data), output.calderaEqualizer);
  });
  test('reject unknown methods, extra fields, graph strings and invalid DSP numbers', () {
    final output = FakeCalderaEqualizer();
    final commands = CalderaMeshEqualizer(output);
    for (final (method, payload) in [
      ('SetState', {'enabled': true}),
      ('SetSinkEqualizerEnabled', {'enabled': 1}),
      ('SetSinkEqualizerEnabled', {'enabled': true, 'source': 'other'}),
      ('SetSinkEqualizerGain', {'gain': double.nan}),
      ('SetSinkEqualizerGain', {'gain': 25}),
      ('SetSinkEqualizerBands', {'bands': 'equalizer=f=1'}),
      (
        'SetSinkEqualizerBands',
        {
          'bands': [
            {'filterType': 99, 'frequency': 1000, 'gain': 2, 'q': 1},
          ],
        },
      ),
      (
        'SetSinkEqualizerBands',
        {
          'bands': [
            {'filterType': 0, 'frequency': 1000, 'gain': 2, 'q': 0},
          ],
        },
      ),
      (
        'SetSinkEqualizerBands',
        {
          'bands': List.filled(33, {'filterType': 0, 'frequency': 1000, 'gain': 2, 'q': 1}),
        },
      ),
    ]) {
      expect(() => commands.apply(method, payload, current: () => true, changed: () {}), throwsFormatException);
    }
    expect(output.writes, isEmpty);
  });
  test('retired scopes cannot finish or replay queued settings', () async {
    final output = FakeCalderaEqualizer()..gate = Completer<void>();
    final commands = CalderaMeshEqualizer(output);
    var current = true, changes = 0;
    final first = commands.apply(
      'SetSinkEqualizerGain',
      {'gain': -3},
      current: () => current,
      changed: () => changes++,
    );
    final second = commands.apply(
      'SetSinkEqualizerEnabled',
      {'enabled': true},
      current: () => current,
      changed: () => changes++,
    );
    final checks = [expectLater(first, throwsStateError), expectLater(second, throwsStateError)];
    await Future<void>.delayed(Duration.zero);
    current = false;
    output.gate!.complete();
    await Future.wait(checks);
    expect(output.writes, isEmpty);
    expect(changes, 0);
  });
  test('pending limit and native error keep the serial queue bounded and reusable', () async {
    final output = FakeCalderaEqualizer()
      ..gate = Completer<void>()
      ..fail = true;
    final commands = CalderaMeshEqualizer(output);
    final checks = <Future<void>>[];
    for (var i = 0; i < 32; i++) {
      checks.add(
        expectLater(
          commands.apply('SetSinkEqualizerGain', {'gain': -3}, current: () => true, changed: () {}),
          throwsStateError,
        ),
      );
    }
    expect(
      () => commands.apply('SetSinkEqualizerGain', {'gain': -3}, current: () => true, changed: () {}),
      throwsStateError,
    );
    output.gate!.complete();
    await Future.wait(checks);
    output.fail = false;
    await commands.apply('SetSinkEqualizerEnabled', {'enabled': true}, current: () => true, changed: () {});
    expect(output.calderaEqualizer.enabled, isTrue);
  });
}
