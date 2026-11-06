import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
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
    url: Uri.parse('https://www.youtube.com/watch?v=1234567890$index'),
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

  testWidgets('revoking external access removes a visible handoff and QR immediately on refresh', (tester) async {
    final state = session();
    addTearDown(state.dispose);
    await host(tester, ExtraPlaybackScreen(session: state, entry: entry(0)));
    expect(find.text(t.bonusExtras.openProvider), findsOneWidget);
    await state.store.savePreferences(const ExtrasPreferences(externalEnabled: false));
    await state.refresh();
    await tester.pumpAndSettle();
    expect(find.text(t.bonusExtras.openProvider), findsNothing);
    expect(find.text(t.bonusExtras.sendToPhone), findsNothing);
    expect(find.text(t.bonusExtras.playbackBlocked), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unconfigured title explains setup and does not offer a dead discovery action', (tester) async {
    final state = session()..entries = [];
    addTearDown(state.dispose);
    await host(tester, ExtrasScreen(session: state));
    expect(find.text(t.bonusExtras.setupHint), findsOneWidget);
    expect(find.text(t.bonusExtras.findMore), findsNothing);
    expect(find.text(t.bonusExtras.empty), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets('stalled embed on ${platform.name} returns to provider and QR after its deadline', (tester) async {
      InAppWebViewPlatform.instance = _ExtraWebPlatform();
      final state = session();
      addTearDown(state.dispose);
      await host(tester, ExtraPlaybackScreen(session: state, entry: entry(0)), scale: 1);
      await tester.tap(find.text(t.bonusExtras.watchHere));
      await tester.pump();
      expect(find.byType(InAppWebView), findsOneWidget);
      await tester.pump(const Duration(seconds: 16));
      await tester.pumpAndSettle();
      expect(find.byType(InAppWebView), findsNothing);
      expect(find.text(t.bonusExtras.playbackUnavailable), findsOneWidget);
      expect(find.text(t.bonusExtras.openProvider), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
  }

  testWidgets('ready embed preserves playback and selected-video completion updates the resume handoff', (
    tester,
  ) async {
    final platform = _ExtraWebPlatform();
    InAppWebViewPlatform.instance = platform;
    final state = session();
    addTearDown(state.dispose);
    await host(tester, ExtraPlaybackScreen(session: state, entry: entry(0), start: 12), scale: 1);
    await tester.tap(find.text(t.bonusExtras.watchHere));
    await tester.pump();
    final surface = platform.latest!;
    expect(surface.params.initialSettings!.javaScriptHandlersForMainFrameOnly, true);
    expect(surface.params.initialSettings!.javaScriptBridgeOriginAllowList, {'https://pleazyng.app'});
    await surface.controller.send('ready', 0);
    await tester.pump(const Duration(seconds: 16));
    expect(find.byType(InAppWebView), findsOneWidget);
    await surface.controller.send('position', double.nan);
    await surface.controller.send('position', 82);
    expect((await state.store.progress('0'))['completed'], false);
    await surface.controller.send('ended', 90);
    await tester.pumpAndSettle();
    expect(find.byType(InAppWebView), findsNothing);
    expect((await state.store.progress('0'))['completed'], true);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.ensureVisible(find.text(t.bonusExtras.copyLink));
    await tester.tap(find.text(t.bonusExtras.copyLink));
    await tester.pump();
    expect(Uri.parse(copied!).queryParameters['t'], '90s');
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('missing native webview implementation falls back without an uncaught build error', (tester) async {
    InAppWebViewPlatform.instance = _ExtraWebPlatform(unavailable: true);
    final state = session();
    addTearDown(state.dispose);
    await host(tester, ExtraPlaybackScreen(session: state, entry: entry(0)), scale: 1);
    await tester.tap(find.text(t.bonusExtras.watchHere));
    await tester.pumpAndSettle();
    expect(find.text(t.bonusExtras.playbackUnavailable), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));
}

class _ExtraWebPlatform extends InAppWebViewPlatform {
  _ExtraWebPlatform({this.unavailable = false});
  final bool unavailable;
  _ExtraWebSurface? latest;
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(PlatformInAppWebViewWidgetCreationParams params) {
    if (unavailable) throw UnimplementedError('WebView runtime unavailable');
    return latest = _ExtraWebSurface(params);
  }
}

class _ExtraWebSurface extends PlatformInAppWebViewWidget {
  _ExtraWebSurface(super.params) : super.implementation();
  final controller = _ExtraWebController();
  bool created = false;
  @override
  Widget build(BuildContext context) {
    if (!created) {
      created = true;
      params.onWebViewCreated?.call(controllerFromPlatform<InAppWebViewController>(controller));
    }
    return const SizedBox.expand();
  }

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      InAppWebViewController.fromPlatform(platform: controller) as T;
  @override
  void dispose() {}
}

class _ExtraWebController extends PlatformInAppWebViewController {
  _ExtraWebController() : super.implementation(const PlatformInAppWebViewControllerCreationParams(id: 'extra-test'));
  final handlers = <String, Function>{};
  @override
  void addJavaScriptHandler({required String handlerName, required Function callback}) =>
      handlers[handlerName] = callback;
  Future<void> send(String kind, num value) async => await Function.apply(handlers['extras']!, [
    [kind, value],
  ]);
}
