import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/extras/extras_models.dart';
import 'package:plezy/extras/extras_playback.dart';
import 'package:plezy/extras/extras_screen.dart';
import 'package:plezy/extras/extras_session.dart';
import 'package:plezy/extras/extras_store.dart';
import 'package:plezy/extras/extras_widgets.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/utils/platform_detector.dart';
import '../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);
  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));
  ExtraEntry entry(int index) => ExtraEntry(
    id: '$index',
    title: 'A long behind the scenes feature about practical makeup and miniatures $index',
    parentIdentities: const {'movie/tmdb:120'},
    kind: ExtraKind.makingOf,
    origin: ExtraOrigin.reviewed,
    reviewedAssociation: true,
    url: Uri.parse('https://www.youtube.com/watch?v=12345678901'),
    publisher: 'Production studio',
  );
  ExtrasSession session() => ExtrasSession(
    subject: const ExtrasSubject(
      key: 'movie/tmdb:120',
      identities: {'movie/tmdb:120'},
      title: 'Fellowship',
      watched: true,
    ),
    store: ExtrasStore('test'),
  )..entries = [for (var i = 0; i < 6; i++) entry(i)];
  Future<void> host(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(320, 640),
    bool rtl = false,
    double scale = 2,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
          child: Directionality(textDirection: rtl ? TextDirection.rtl : TextDirection.ltr, child: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final rtl in [false, true]) {
    testWidgets('browser is scrollable at 320px and 200% text, RTL=$rtl', (tester) async {
      final state = session();
      addTearDown(state.dispose);
      await host(tester, ExtrasScreen(session: state), rtl: rtl);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), 'makeup');
      await tester.pump();
      expect(find.textContaining('practical makeup'), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('preview renders at most four entries and opens the full browser', (tester) async {
    final state = session();
    addTearDown(state.dispose);
    await host(
      tester,
      Scaffold(body: ExtrasShelf(session: state)),
      size: const Size(1920, 1080),
      scale: 1,
    );
    expect(find.byType(ExtraCard), findsNWidgets(4));
    await tester.tap(find.text(t.bonusExtras.seeAll));
    await tester.pumpAndSettle();
    expect(find.byType(ExtrasScreen), findsOneWidget);
    expect(state.entries, hasLength(6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings and QR fallback fit small screens at large text', (tester) async {
    final state = session();
    addTearDown(state.dispose);
    await host(tester, ExtrasSettingsScreen(session: state));
    expect(tester.takeException(), isNull);
    await host(tester, ExtraPlaybackScreen(session: state, entry: entry(0)), rtl: true);
    expect(find.text(t.bonusExtras.openProvider), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV fallback has provider and QR actions without an unsupported webview', (tester) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    addTearDown(() => TvDetectionService.debugSetAppleTVOverride(null));
    final state = session();
    addTearDown(state.dispose);
    await host(
      tester,
      ExtraPlaybackScreen(session: state, entry: entry(0)),
      size: const Size(1920, 1080),
      scale: 1.5,
    );
    expect(find.text(t.bonusExtras.watchHere), findsNothing);
    expect(find.text(t.bonusExtras.copyLink), findsNothing);
    expect(find.text(t.bonusExtras.sendToPhone), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
