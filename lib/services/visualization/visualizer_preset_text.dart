import 'dart:convert';

/// Same byte policy as MilkRust's native loader. Validation never changes the
/// installed bytes, so archive integrity and upstream attribution stay intact.
abstract final class VisualizerPresetText {
  static const maxBytes = 2 * 1024 * 1024;
  static String decode(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('Preset text is empty or larger than 2 MB.');
    }
    String text;
    if (bytes.length >= 2 && ((bytes[0] == 0xff && bytes[1] == 0xfe) || (bytes[0] == 0xfe && bytes[1] == 0xff))) {
      if (bytes.length.isOdd) throw const FormatException('Truncated UTF-16 preset.');
      final little = bytes[0] == 0xff;
      final codePoints = <int>[];
      int unit(int i) => little ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1];
      for (var i = 2; i < bytes.length; i += 2) {
        var c = unit(i);
        if (c >= 0xd800 && c <= 0xdbff) {
          if (i + 3 >= bytes.length) throw const FormatException('Malformed UTF-16 preset.');
          final low = unit(i + 2);
          if (low < 0xdc00 || low > 0xdfff) throw const FormatException('Malformed UTF-16 preset.');
          c = 0x10000 + ((c - 0xd800) << 10) + low - 0xdc00;
          i += 2;
        } else if (c >= 0xdc00 && c <= 0xdfff) {
          throw const FormatException('Malformed UTF-16 preset.');
        }
        codePoints.add(c);
      }
      text = String.fromCharCodes(codePoints);
    } else {
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        const high = [
          0x20ac, 0, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
          0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017d, 0,
          0, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
          0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0, 0x017e, 0x0178,
        ];
        text = String.fromCharCodes(bytes.map((byte) {
          if (byte >= 0x80 && byte <= 0x9f) {
            final c = high[byte - 0x80];
            if (c == 0) throw const FormatException('Undefined Windows-1252 byte in preset.');
            return c;
          }
          return byte;
        }));
      }
    }
    if (text.startsWith('\ufeff')) text = text.substring(1);
    if (text.isEmpty || utf8.encode(text).length > maxBytes ||
        text.runes.any((c) => (c < 0x20 && !{9, 10, 11, 12, 13}.contains(c)) || (c >= 0x7f && c <= 0x9f))) {
      throw const FormatException('Decoded preset is empty, binary, or larger than 2 MB.');
    }
    return text;
  }
}
