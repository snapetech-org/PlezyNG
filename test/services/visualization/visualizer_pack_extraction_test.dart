import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/services/visualization/visualizer_pack_store.dart';

import '../../test_helpers/io_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late PathProviderPlatform previous;

  setUpAll(() {
    temporary = Directory.systemTemp.createTempSync('plezy-pack-extraction-');
    previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(temporary);
  });
  tearDownAll(() {
    PathProviderPlatform.instance = previous;
    temporary.deleteSync(recursive: true);
  });

  Uint8List archive(CompressionType compression) {
    final content = utf8.encode(jsonEncode({'unused': 'repeated data ' * 12000}));
    final file = ArchiveFile('manifest.json', content.length, content)..compression = compression;
    return ZipEncoder().encodeBytes(Archive()..addFile(file));
  }

  Future<void> rejects(Uint8List bytes, Matcher error) async {
    final selected = File('${temporary.path}/selected.rmpack')..writeAsBytesSync(bytes);
    final store = VisualizerPackStore();
    await expectLater(store.importPackFile(selected.path, bytes.length), throwsA(error));
    final installed = Directory('${temporary.path}/support/visualizer/community-packs');
    expect(installed.listSync(), isEmpty, reason: 'Failed extraction must remove staging files and snapshots.');
  }

  for (final compression in [CompressionType.none, CompressionType.deflate]) {
    test('bounded output extracts $compression content before manifest validation', () async {
      // A valid JSON document with deliberately missing manifest fields proves
      // that stored/deflated bytes survived the full streaming extraction path.
      await rejects(
        archive(compression),
        isA<VisualizerPackException>().having((e) => e.message, 'message', 'The pack manifest is malformed.'),
      );
    });
  }

  test('underdeclared compressed size cannot publish a pack', () async {
    final bytes = archive(CompressionType.deflate);
    final data = ByteData.sublistView(bytes);
    var patched = 0;
    for (var offset = 0; offset + 46 <= bytes.length; offset++) {
      final signature = data.getUint32(offset, Endian.little);
      if (signature == 0x04034b50) {
        data.setUint32(offset + 22, 16, Endian.little);
        patched++;
      } else if (signature == 0x02014b50) {
        data.setUint32(offset + 24, 16, Endian.little);
        patched++;
      }
    }
    expect(patched, 2);
    await rejects(bytes, isA<VisualizerPackException>());
  });
}
