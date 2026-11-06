import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/games/romm_manual_view.dart';

import '../../scripts/tizen/romm_manual_view.dart' as tv;

void main() {
  testWidgets('supported manual viewer retains the PDF bytes and source identity', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final bytes = Uint8List.fromList([0x25, 0x50, 0x44, 0x46, 0x2d]);
    final view = RommManualView(bytes: bytes, sourceName: 'romm-42.pdf');
    final viewer = view.build(tester.element(find.byType(SizedBox))) as PdfViewer;
    expect(RommManualView.supported, isTrue);
    final document = viewer.documentRef as PdfDocumentRefData;
    expect(identical(document.data, bytes), isTrue);
    expect(document.key.sourceName, 'romm-42.pdf');
  });

  testWidgets('TV adapter reports the unsupported capability without opening PDFium', (tester) async {
    expect(tv.RommManualView.supported, isFalse);
    await tester.pumpWidget(
      MaterialApp(
        home: tv.RommManualView(bytes: Uint8List(0), sourceName: 'romm-42.pdf'),
      ),
    );
    expect(find.text(t.fileSources.errorUnsupported), findsOneWidget);
    expect(find.byType(PdfViewer), findsNothing);
  });
}
