import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/pgs_subtitles.dart';
import 'package:plezy/mpv/player/platform/webos_pgs_overlay.dart';

import '../fixtures/pgs_fixture.dart';

void main() {
  testWidgets('paints correctly premultiplied PGS pixels inside a letterboxed canvas and clears them', (tester) async {
    final subtitles = PgsSubtitles.parse(syntheticPgsFixture());
    final cue = ValueNotifier<PgsCue?>(subtitles.at(const Duration(seconds: 1)));
    final boundary = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: boundary,
            child: SizedBox(
              width: 8,
              height: 8,
              child: ColoredBox(
                color: const Color(0xff000000),
                child: WebOSPgsOverlay(cue: cue),
              ),
            ),
          ),
        ),
      ),
    );
    for (var attempt = 0; attempt < 100 && find.byType(RawImage).evaluate().isEmpty; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byType(RawImage), findsOneWidget);
    final bytes = await tester.runAsync(() async {
      final image = await (boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
      try {
        return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    });
    {
      final pixels = bytes!;
      final pixel = pixels.sublist((4 * 8 + 3) * 4, (4 * 8 + 3) * 4 + 4);
      expect(pixel.take(3), everyElement(inInclusiveRange(127, 129)));
      expect(pixel.last, 255);
      expect(pixels.sublist(0, 4), [0, 0, 0, 255]);
    }
    cue.value = subtitles.at(const Duration(seconds: 2));
    await tester.pump();
    expect(find.byType(RawImage), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    cue.dispose();
    expect(tester.takeException(), isNull);
  });
}
