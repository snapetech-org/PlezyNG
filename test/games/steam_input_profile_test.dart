import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/games/steam_input_profile.dart';

void main() {
  test('layouts round trip without sharing mutable seat lists', () {
    final defaults = SteamInputProfile.defaults();
    final edited = defaults.change(2, 1, -1).change(2, 16, 4096).change(2, 18, 63);
    expect(defaults.isDefault, isTrue);
    expect(edited.isDefault, isFalse);
    expect(SteamInputProfile.decode(edited.encode()).seats, edited.seats);
    expect(edited.resetSeat(2).isDefault, isTrue);
    expect(() => edited.seats[2][1] = 3, throwsUnsupportedError);
    expect(() => edited.seats.clear(), throwsUnsupportedError);
  });
  test('corrupt, oversized and future profiles restore safe defaults', () {
    for (final data in [
      '',
      'x' * 4097,
      '{}',
      '{"version":2,"seats":[]}',
      jsonEncode({'version': 1, 'seats': List.filled(4, List.filled(19, true))}),
    ]) {
      expect(SteamInputProfile.restore(data).isDefault, isTrue);
    }
    final profile = SteamInputProfile.defaults();
    for (final change in [(1, -2), (1, 15), (16, 8193), (17, -1), (18, 64)]) {
      expect(() => profile.change(0, change.$1, change.$2), throwsFormatException);
    }
  });
}
