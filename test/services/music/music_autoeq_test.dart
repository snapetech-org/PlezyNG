import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/music_autoeq.dart';

void main() {
  test('every bundled model has a valid ten-band response and source identity', () {
    final catalog = MusicAutoEq.parse(File('assets/music/autoeq.json').readAsStringSync());
    expect(catalog, hasLength(6029));
    expect(catalog.map((preset) => preset.source).toSet(), hasLength(catalog.length));
    for (final preset in catalog) {
      expect(preset.name, isNotEmpty);
      expect(preset.source, startsWith('eq/'));
      expect(preset.bands, hasLength(10));
      expect(preset.policy.validate, returnsNormally);
    }
    final matches = MusicAutoEq.search(catalog, 'sEnNhEiSeR HD 600');
    expect(matches, isNotEmpty);
    expect(matches.every((preset) => preset.name.toLowerCase().contains('sennheiser')), isTrue);
    expect(MusicAutoEq.search(catalog, 'no such headphone model 999999'), isEmpty);
  });
  test('malformed or excessive EQ values cannot reach the audio engine', () {
    expect(() => MusicAutoEq.parse(jsonEncode({'version': 2, 'profiles': []})), throwsFormatException);
    expect(
      () => MusicAutoEq.parse(
        jsonEncode({
          'version': 1,
          'profiles': [
            {'name': 'Invalid', 'source': 'eq/a.txt', 'bands': List.filled(10, 100)},
          ],
        }),
      ),
      throwsArgumentError,
    );
  });
}
