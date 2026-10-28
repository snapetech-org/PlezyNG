import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/subtitle_archive_importer.dart';

const _subtitle = '1\n00:00:01,000 --> 00:00:02,000\nHello\n';

Archive _archive({String name = 'captions/en.srt'}) {
  final bytes = utf8.encode(_subtitle);
  return Archive()..addFile(ArchiveFile(name, bytes.length, bytes));
}

SubtitleArchiveDocument _open(Uint8List bytes, String name) =>
    SubtitleArchiveImporter.open(bytes, fileName: name, supportedExtensions: const {'.srt'});

void _checksum(Uint8List tar) {
  tar.fillRange(148, 156, 32);
  final sum = tar.take(512).fold<int>(0, (value, byte) => value + byte);
  tar.setRange(148, 156, ascii.encode('${sum.toRadixString(8).padLeft(6, '0')}\u0000 '));
}

void main() {
  for (final format in ['zip', 'tar', 'tar.gz', 'tgz']) {
    test('opens a bounded $format subtitle archive', () {
      final tar = TarEncoder().encode(_archive());
      final bytes = switch (format) {
        'zip' => ZipEncoder().encodeBytes(_archive()),
        'tar' => Uint8List.fromList(tar),
        _ => Uint8List.fromList(GZipEncoder().encode(tar)),
      };
      expect(_open(bytes, 'captions.$format').candidates.single.displayName, 'captions/en.srt');
    });
  }

  test('rejects non-octal TAR sizes even with a valid header checksum', () {
    final tar = Uint8List.fromList(TarEncoder().encode(_archive()));
    tar[124] = '8'.codeUnitAt(0);
    _checksum(tar);
    expect(() => _open(tar, 'captions.tar'), throwsFormatException);
  });

  test('rejects oversized TAR members before reading member data', () {
    final tar = Uint8List.fromList(TarEncoder().encode(_archive()));
    final size = SubtitleArchiveImporter.maximumMemberBytes + 1;
    tar.setRange(124, 136, ascii.encode('${size.toRadixString(8).padLeft(11, '0')}\u0000'));
    _checksum(tar);
    expect(() => _open(tar, 'captions.tar'), throwsFormatException);
  });

  test('requires both TAR end markers', () {
    final tar = Uint8List.fromList(TarEncoder().encode(_archive()));
    expect(() => _open(Uint8List.sublistView(tar, 0, 1536), 'captions.tar'), throwsFormatException);
  });

  for (final format in ['zip', 'tar']) {
    test('rejects traversal paths in $format', () {
      final archive = _archive(name: '../escape.srt');
      final bytes = format == 'zip'
          ? ZipEncoder().encodeBytes(archive)
          : Uint8List.fromList(TarEncoder().encode(archive));
      expect(() => _open(bytes, 'captions.$format'), throwsFormatException);
    });
  }

  test('rejects ZIP output that exceeds its declared uncompressed size', () {
    final bytes = ZipEncoder().encodeBytes(_archive());
    final view = ByteData.sublistView(bytes);
    var changed = 0;
    for (var offset = 0; offset + 46 <= bytes.length; offset++) {
      final signature = view.getUint32(offset, Endian.little);
      if (signature == 0x04034b50) {
        view.setUint32(offset + 22, 1, Endian.little);
        changed++;
      } else if (signature == 0x02014b50) {
        view.setUint32(offset + 24, 1, Endian.little);
        changed++;
      }
    }
    expect(changed, 2);
    expect(() => _open(bytes, 'captions.zip'), throwsFormatException);
  });
}
