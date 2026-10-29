import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'subtitle_codec_tables.dart';
import 'subtitle_retimer.dart';

/// Explicit decoding only: bytes are never replaced or silently guessed.
/// Derived files use UTF-8; existing source bytes and their encoding stay intact.
abstract final class SubtitleTextCodec {
  static const encodings = <String, String>{
    'unicode': 'Unicode (UTF-8 or BOM-marked UTF-16)',
    'cp1252': 'Windows-1252 · Western Europe',
    'cp1250': 'Windows-1250 · Central Europe',
    'cp1251': 'Windows-1251 · Cyrillic',
    'cp1253': 'Windows-1253 · Greek',
    'cp1254': 'Windows-1254 · Turkish',
    'cp1255': 'Windows-1255 · Hebrew',
    'cp1256': 'Windows-1256 · Arabic',
    'cp1257': 'Windows-1257 · Baltic',
    'cp1258': 'Windows-1258 · Vietnamese',
    'cp932': 'Windows-932 / Shift-JIS · Japanese',
    'gbk': 'GBK / Windows-936 · Simplified Chinese',
    'gb18030': 'GB18030 · Chinese (CPython mapping)',
    'big5': 'Big5 · Traditional Chinese',
    'cp949': 'Windows-949 / UHC · Korean',
    'latin_1': 'ISO-8859-1 · Latin-1',
    'iso8859_2': 'ISO-8859-2 · Latin-2',
    'iso8859_5': 'ISO-8859-5 · Cyrillic',
    'iso8859_6': 'ISO-8859-6 · Arabic',
    'iso8859_7': 'ISO-8859-7 · Greek',
    'iso8859_8': 'ISO-8859-8 · Hebrew (logical order only)',
    'iso8859_9': 'ISO-8859-9 · Turkish',
    'iso8859_15': 'ISO-8859-15 · Latin-9',
    'koi8_r': 'KOI8-R · Russian',
    'koi8_u': 'KOI8-U · Ukrainian',
    'cp437': 'DOS-437', 'cp850': 'DOS-850', 'cp866': 'DOS-866 · Cyrillic',
    'utf16le': 'UTF-16 little-endian without BOM',
    'utf16be': 'UTF-16 big-endian without BOM',
  };

  static final _cache = <String, ByteData>{};
  static const _double = {'cp932', 'gbk', 'gb18030', 'big5', 'cp949'};

  static String decode(List<int> bytes, {String encoding = 'unicode'}) {
    if (bytes.isEmpty || bytes.length > SubtitleRetimer.maximumInputBytes || bytes.any((b) => b < 0 || b > 255)) {
      throw const FormatException('Text subtitle input must be between 1 byte and 5 MiB.');
    }
    if (encoding == 'unicode') return SubtitleRetimer.decodeUnicode(bytes);
    if (encoding == 'utf16le' || encoding == 'utf16be') {
      return SubtitleRetimer.decodeUnicode([if (encoding == 'utf16le') ...[0xff, 0xfe] else ...[0xfe, 0xff], ...bytes]);
    }
    final encoded = subtitleCodecTables[encoding];
    if (encoded == null) throw ArgumentError.value(encoding, 'encoding', 'Unknown subtitle encoding');
    final table = _cache.putIfAbsent(encoding, () {
      final bytes = Uint8List.fromList(ZLibDecoder().decodeBytes(base64.decode(encoded)));
      final expected = (_double.contains(encoding) ? 256 + 65536 : 256) * 4;
      if (bytes.length != expected) throw StateError('Invalid bundled encoding table.');
      return ByteData.sublistView(bytes);
    });
    final output = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      final first = bytes[i];
      var scalar = table.getUint32(first * 4, Endian.little);
      if (scalar == 0xffffffff && _double.contains(encoding) && i + 1 < bytes.length) {
        final second = bytes[++i];
        if (encoding == 'gb18030' && first >= 0x81 && first <= 0xfe && second >= 0x30 && second <= 0x39) {
          if (i + 2 >= bytes.length) throw const FormatException('Incomplete GB18030 four-byte sequence.');
          final third = bytes[++i], fourth = bytes[++i];
          if (third < 0x81 || third > 0xfe || fourth < 0x30 || fourth > 0x39) {
            throw const FormatException('Invalid GB18030 four-byte sequence.');
          }
          final pointer = ((first - 0x81) * 10 + second - 0x30) * 1260 + (third - 0x81) * 10 + fourth - 0x30;
          var lo = 0, hi = subtitleGb18030Ranges.length - 1;
          while (lo <= hi) {
            final mid = (lo + hi) ~/ 2, range = subtitleGb18030Ranges[(lo + hi) ~/ 2];
            if (pointer < range[0]) { hi = mid - 1; }
            else if (pointer > range[1]) { lo = mid + 1; }
            else { scalar = range[2] + pointer - range[0]; break; }
          }
        } else {
          scalar = table.getUint32((256 + first * 256 + second) * 4, Endian.little);
        }
      }
      if (scalar == 0xffffffff) throw FormatException('Invalid $encoding sequence near byte $i. Choose a different encoding.');
      if (scalar == 0 || (scalar < 0x20 && scalar != 9 && scalar != 10 && scalar != 13)) {
        throw const FormatException('The selected encoding produces binary control characters.');
      }
      output.writeCharCode(scalar);
    }
    return output.toString();
  }
}
