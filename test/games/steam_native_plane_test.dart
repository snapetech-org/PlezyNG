import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/games/steam_native_plane.dart';

void main() {
  testWidgets('plane follows physical geometry and hides its retained Offstage owner', (tester) async {
    final rects = <Map<String, int>>[];
    final key = GlobalKey();
    Widget tree(bool hidden, double dpr) => MediaQuery(
      data: MediaQueryData(devicePixelRatio: dpr),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: Offstage(
            offstage: hidden,
            child: SizedBox(
              width: 120,
              height: 80,
              child: SteamNativePlane(key: key, enabled: true, onRect: rects.add),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(tree(false, 1.5));
    expect(rects.last['width'], 180);
    expect(rects.last['height'], 120);
    expect(rects.last['scale'], 2);
    await tester.pumpWidget(tree(true, 1.5));
    expect(rects.last['width'], 0);
    await tester.pumpWidget(tree(false, 2));
    expect(rects.last['width'], 240);
    await tester.pumpWidget(const SizedBox());
    expect(rects.last['width'], 0);
  });

  testWidgets('native plane clears its aperture while Flutter controls stay opaque', (tester) async {
    final capture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.red,
            body: Stack(
              children: [
                const Positioned.fill(child: ColoredBox(color: Colors.black)),
                Positioned(
                  left: 20,
                  top: 20,
                  width: 100,
                  height: 100,
                  child: SteamNativePlane(enabled: true, onRect: (_) {}),
                ),
                const Positioned(left: 30, top: 30, width: 10, height: 10, child: ColoredBox(color: Colors.blue)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = (await tester.runAsync(() => boundary.toImage()))!;
    final data = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    int alpha(int x, int y) => data.getUint8((y * image.width + x) * 4 + 3);
    expect(alpha(50, 50), 0);
    expect(alpha(35, 35), 255);
    expect(alpha(5, 5), 255);
    image.dispose();
  });
}
