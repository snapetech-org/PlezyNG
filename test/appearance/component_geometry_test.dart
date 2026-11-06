import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/theme/theme_package.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:plezy/widgets/media_grid_delegate.dart';
import 'package:plezy/widgets/skeleton_media_card.dart';
import 'package:plezy/widgets/overlay_sheet.dart';
import 'package:plezy/widgets/settings_page.dart';
import 'package:plezy/widgets/settings_section.dart';
import 'package:plezy/widgets/video_controls/widgets/video_timeline_bar.dart';
import '../test_helpers/prefs.dart';
import 'appearance_fixtures.dart';

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  testWidgets('loading and loaded artwork have identical bounds at every caption scale and spacing', (tester) async {
    for (final scale in [1.0, 2.0]) {
      for (final spacing in GridSpacing.values) {
        await SettingsService.instance.write(SettingsService.gridSpacing, spacing);
        await tester.pumpWidget(
          appearanceApp(
            textScale: scale,
            child: Scaffold(
              body: Builder(
                builder: (context) {
                  final height = MediaGridDelegate.cellHeightFor(context: context, itemWidth: 160);
                  return Row(
                    children: [
                      SizedBox(
                        width: 160,
                        height: height,
                        child: MediaCard(item: appearanceMovie, viewModeOverride: ViewMode.grid, isOffline: true),
                      ),
                      SizedBox(width: 160, height: height, child: const SkeletonMediaCard()),
                    ],
                  );
                },
              ),
            ),
          ),
        );
        await tester.pump();
        final actual = find.descendant(of: find.byType(MediaCard), matching: find.byType(ClipRRect)).first;
        final skeleton = find
            .descendant(of: find.byType(SkeletonMediaCard), matching: find.byType(SkeletonLoader))
            .first;
        expect(tester.getSize(skeleton), tester.getSize(actual), reason: '$scale, $spacing');
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('settings use actual pane width and stay centred on ultrawide screens', (tester) async {
    tester.view.physicalSize = const Size(3440, 1440);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final width in [320.0, 960.0, 2000.0]) {
      await tester.pumpWidget(
        appearanceApp(
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: width,
              child: SettingsPage(
                title: const Text('Appearance'),
                children: const [
                  SettingsGroup(children: [ListTile(title: Text('Setting'))]),
                ],
              ),
            ),
          ),
        ),
      );
      final row = tester.getRect(find.byType(ListTile));
      expect(row.width, lessThanOrEqualTo(928));
      expect(row.center.dx, closeTo(width / 2, .01));
      expect(tester.takeException(), isNull);
    }
  });

  for (final hosted in [false, true]) {
    testWidgets('sheet stays above keyboard and uses custom corners (hosted=$hosted)', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const body = Key('sheet_body');
      late BuildContext launchContext;
      final theme = const ThemePackage(
        id: 'test',
        name: 'Test',
        palette: MonoPalette.dark,
        radiusLg: 32,
      ).apply(monoTheme(MonoPalette.dark));
      final launcher = Scaffold(
        body: Builder(
          builder: (context) {
            launchContext = context;
            return const Text('Open');
          },
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(viewInsets: const EdgeInsets.only(bottom: 300), disableAnimations: true),
            child: child!,
          ),
          home: hosted ? OverlaySheetHost(child: launcher) : launcher,
        ),
      );
      final result = OverlaySheetController.showAdaptive<void>(
        launchContext,
        isScrollControlled: true,
        builder: (_) => SingleChildScrollView(
          child: Column(
            key: body,
            children: [
              const TextField(),
              const SizedBox(height: 300),
              TextButton(onPressed: () {}, child: const Text('Save')),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final material = find.ancestor(of: find.byKey(body), matching: find.byType(Material)).first;
      final scrollViewport = find.ancestor(of: find.byKey(body), matching: find.byType(SingleChildScrollView)).first;
      expect(tester.getRect(scrollViewport).bottom, lessThanOrEqualTo(544), reason: 'controls must clear keyboard');
      final widget = tester.widget<Material>(material);
      final radius = widget.borderRadius ?? (widget.shape as RoundedRectangleBorder).borderRadius;
      expect(radius.resolve(TextDirection.ltr).topLeft, const Radius.circular(32));
      expect(tester.takeException(), isNull);
      OverlaySheetController.closeAdaptive(tester.element(find.byKey(body)));
      await tester.pumpAndSettle();
      await result;
    });
  }

  for (final horizontal in [false, true]) {
    testWidgets('long playback times retain a usable track at enlarged text (horizontal=$horizontal)', (tester) async {
      tester.view.physicalSize = const Size(280, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        appearanceApp(
          textScale: 2,
          direction: TextDirection.rtl,
          child: Scaffold(
            body: Center(
              child: VideoTimelineBar(
                player: AppearanceFakePlayer(),
                chapters: const [],
                chaptersLoaded: true,
                onSeek: (_) {},
                onSeekEnd: (_) {},
                horizontalLayout: horizontal,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(Slider)).width, greaterThan(120));
      expect(tester.widget<Text>(find.text('-1:23:00')).textDirection, TextDirection.ltr);
    });
  }
}
