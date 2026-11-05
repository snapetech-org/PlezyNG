import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/widgets/app_brand.dart';

void main() {
  testWidgets('branding updates when the surface changes between light and dark', (tester) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const Scaffold(body: Column(children: [AppBrandMark(), AppBrandWordmark()])),
        ),
      );
      await tester.pumpAndSettle();
      final assets = tester.widgetList<Image>(find.byType(Image)).map((image) => (image.image as AssetImage).assetName);
      expect(assets, contains('assets/branding/pleazyng-mark-${brightness.name}.png'));
      expect(assets, contains('assets/branding/pleazyng-wordmark-${brightness.name}.png'));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('small marks omit fine lettering and custom surfaces choose legible branding', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: const ColorScheme.light(surface: Color(0xFF071527), onSurface: Color(0x1AFFFFFF)),
        ),
        home: const Scaffold(body: Column(children: [AppBrandMark(size: 32), AppBrandWordmark()])),
      ),
    );
    final assets = tester.widgetList<Image>(find.byType(Image)).map((image) => (image.image as AssetImage).assetName);
    expect(assets, contains('assets/branding/pleazyng-monochrome.png'));
    expect(assets, contains('assets/branding/pleazyng-wordmark-dark.png'));
    expect(tester.widgetList<Image>(find.byType(Image)).first.color, Colors.white);
    expect(tester.takeException(), isNull);
  });

  testWidgets('page loading respects reduced motion and excludes decorative branding', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const Scaffold(body: Center(child: AppLoadingIndicator())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator)).value, 0.75);
    expect(tester.widget<Image>(find.byType(Image)).excludeFromSemantics, isTrue);
    expect(tester.takeException(), isNull);
  });
}
