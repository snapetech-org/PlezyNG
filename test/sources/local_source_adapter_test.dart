import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/sources/adapters/local_source.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_transport.dart';

void main() {
  test('large local directory uses sorted pages across external merge runs', () async {
    final root = await Directory.systemTemp.createTemp('pleazyng-local-source-test-');
    final source = FileSource(
      id: 'local',
      profileId: 'profile',
      kind: FileSourceKind.local,
      name: 'Local',
      root: root.path,
    );
    final adapter = LocalSourceAdapter(source, SourceTransport());
    try {
      for (var index = 20000; index >= 0; index--) {
        File('${root.path}/video-${index.toString().padLeft(5, '0')}.mp4').createSync();
      }

      final actual = <String>[];
      String? cursor;
      do {
        final page = await adapter.browse(cursor: cursor);
        actual.addAll(page.entries.map((entry) => entry.title));
        cursor = page.next;
      } while (cursor != null);

      expect(actual, hasLength(20001));
      expect(actual, List.generate(20001, (index) => 'video-${index.toString().padLeft(5, '0')}.mp4'));
    } finally {
      adapter.close();
      await root.delete(recursive: true);
    }
  });
}
