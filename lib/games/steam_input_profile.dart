import 'dart:convert';

/// Immutable, bounded receiver mappings. The host's Steam Input layout stays
/// authoritative after this virtual controller's events reach Steam.
class SteamInputProfile {
  SteamInputProfile(List<List<int>> seats) : seats = List.unmodifiable(seats.map(List<int>.unmodifiable)) {
    if (seats.length != 4 || seats.any((seat) => !validLayout(seat))) {
      throw const FormatException('Invalid Steam input profile');
    }
  }

  static const defaultLayout = <int>[1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 0, 0, 0];
  factory SteamInputProfile.defaults() => SteamInputProfile(List.generate(4, (_) => defaultLayout));
  final List<List<int>> seats;
  bool get isDefault => seats.every((seat) => List.generate(19, (i) => seat[i] == defaultLayout[i]).every((v) => v));

  static bool validLayout(List<int> values) =>
      values.length == 19 &&
      values[0] == 1 &&
      values.sublist(1, 16).every((v) => v >= -1 && v <= 14) &&
      values[16] >= 0 &&
      values[16] <= 8192 &&
      values[17] >= 0 &&
      values[17] <= 8192 &&
      values[18] >= 0 &&
      values[18] <= 63;

  factory SteamInputProfile.decode(String text) {
    if (text.length > 4096) throw const FormatException('Input profile too large');
    final value = jsonDecode(text);
    if (value is! Map ||
        value.length != 2 ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['seats'] is! List) {
      throw const FormatException('Invalid input profile');
    }
    final seats = value['seats'] as List;
    if (seats.length != 4 || seats.any((s) => s is! List || s.length != 19 || s.any((v) => v is! int))) {
      throw const FormatException('Invalid input profile');
    }
    return SteamInputProfile(seats.map((s) => List<int>.from(s as List)).toList());
  }

  factory SteamInputProfile.restore(String text) {
    try {
      return SteamInputProfile.decode(text);
    } catch (_) {
      return SteamInputProfile.defaults();
    }
  }
  String encode() => jsonEncode({'version': 1, 'seats': seats});
  SteamInputProfile change(int seat, int index, int value) {
    if (seat < 0 || seat > 3 || index < 1 || index > 18) throw const FormatException('Invalid mapping index');
    final copy = seats.map((s) => s.toList()).toList();
    copy[seat][index] = value;
    return SteamInputProfile(copy);
  }

  SteamInputProfile resetSeat(int seat) {
    final copy = seats.map((s) => s.toList()).toList();
    copy[seat] = defaultLayout;
    return SteamInputProfile(copy);
  }
}
