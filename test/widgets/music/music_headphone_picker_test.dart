import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/music_autoeq.dart';
import 'package:plezy/widgets/music/music_headphone_picker.dart';

void main() {
  testWidgets('headphone search remains usable with large text and an on-screen keyboard', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    MusicHeadphonePreset? chosen;
    await tester.runAsync(() => MusicAutoEq.load());
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                chosen = await pickMusicHeadphone(context);
              },
              child: const Text('AutoEq'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('AutoEq'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField), 'Sennheiser HD 600');
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump(const Duration(milliseconds: 300));
    // The search field contains the same text; select the actual result row.
    final model = find.descendant(of: find.byType(ListTile), matching: find.text('Sennheiser HD 600'));
    await tester.scrollUntilVisible(model, 150, scrollable: find.byType(Scrollable).first);
    final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    position.jumpTo(position.pixels);
    await tester.pump();
    await tester.tap(model);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(chosen?.name, 'Sennheiser HD 600');
    expect(find.byType(Dialog), findsNothing);
  });
}
