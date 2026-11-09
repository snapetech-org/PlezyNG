import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/seerr/seerr_session.dart';
import 'package:plezy/providers/seerr_account_provider.dart';
import 'package:plezy/screens/requests/requests_screen.dart';
import 'package:plezy/services/seerr/seerr_client.dart';
import 'package:plezy/services/seerr/seerr_constants.dart';
import 'package:provider/provider.dart';

import 'package:plezy/theme/mono_theme.dart';

class _Account extends SeerrAccountProvider {
  _Account(this.client);
  SeerrClient? client;
  @override
  SeerrClient? get catalogClient => client;
  void unlink() {
    client = null;
    notifyListeners();
  }
}

http.Response _json(Object data) => http.Response(jsonEncode(data), 200, headers: {'content-type': 'application/json'});
SeerrClient _client(Future<http.Response> Function(http.Request) handler) {
  final client = SeerrClient(
    const SeerrSession(
      baseUrl: 'https://seerr.example.com',
      method: SeerrAuthMethod.local,
      identifier: '',
      secret: '',
      cookie: 'cookie',
      userId: 1,
      permissions: SeerrPermission.request,
      displayName: 'User',
      instanceLabel: 'SeerrNG',
      product: SeerrProduct.jellyseerr,
      createdAt: 0,
    ),
    onSessionInvalidated: () {},
    httpClient: MockClient(handler),
  );
  addTearDown(client.dispose);
  return client;
}

Future<void> _pump(WidgetTester tester, _Account account, {GlobalKey? capture}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<SeerrAccountProvider>.value(
      value: account,
      child: TranslationProvider(
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark).copyWith(
            textTheme: monoTheme(MonoPalette.dark).textTheme.apply(fontFamily: 'Appearance Sans'),
            appBarTheme: monoTheme(MonoPalette.dark).appBarTheme.copyWith(
              titleTextStyle: monoTheme(
                MonoPalette.dark,
              ).appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Appearance Sans'),
            ),
          ),
          home: RepaintBoundary(key: capture, child: const RequestsScreen()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('Appearance Sans')..addFont(rootBundle.load('assets/go-noto-current-regular.ttf'))).load();
    await (FontLoader(
      'packages/material_symbols_icons/MaterialSymbolsRounded',
    )..addFont(rootBundle.load('packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf'))).load();
  });
  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));

  testWidgets('native ebook request stays minimal and hides profile data after unlink', (tester) async {
    Map<String, dynamic>? payload;
    final client = _client((request) async {
      if (request.method == 'POST') {
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return _json({'id': 1});
      }
      if (request.url.path.endsWith('/book/OL123W')) {
        return _json({'id': 'OL123W', 'title': 'A book', 'description': 'Description'});
      }
      if (request.url.path.endsWith('/discover/books')) {
        return _json({
          'totalPages': 1,
          'results': [
            {'id': 'OL123W', 'title': 'A book'},
          ],
        });
      }
      return _json({'results': []});
    });
    final account = _Account(client);
    addTearDown(account.dispose);
    await _pump(tester, account);
    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('TV Shows'), findsOneWidget);
    expect(find.text('Ebooks'), findsOneWidget);
    expect(find.text('Audiobooks'), findsOneWidget);
    await tester.tap(find.text('Ebooks'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discover'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A book'));
    await tester.pumpAndSettle();
    expect(find.text('Description'), findsOneWidget);
    expect(find.text('Destination server'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Request'));
    await tester.pumpAndSettle();
    expect(payload, {'mediaType': 'book', 'mediaId': 'OL123W', 'format': 'ebook'});
    expect(find.text('Request submitted'), findsOneWidget);
    account.unlink();
    await tester.pumpAndSettle();
    expect(find.text('A book'), findsNothing);
    expect(find.text('Description'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Request'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late overview response cannot enter the next profile session', (tester) async {
    final response = Completer<http.Response>();
    final client = _client(
      (request) => request.url.path.endsWith('/request')
          ? response.future
          : Future.value(_json({'id': 123, 'title': 'Private title'})),
    );
    final account = _Account(client);
    addTearDown(account.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<SeerrAccountProvider>.value(
        value: account,
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark).copyWith(
            textTheme: monoTheme(MonoPalette.dark).textTheme.apply(fontFamily: 'Appearance Sans'),
            appBarTheme: monoTheme(MonoPalette.dark).appBarTheme.copyWith(
              titleTextStyle: monoTheme(
                MonoPalette.dark,
              ).appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Appearance Sans'),
            ),
          ),
          home: const RequestsScreen(),
        ),
      ),
    );
    await tester.pump();
    account.unlink();
    await tester.pump();
    response.complete(
      _json({
        'results': [
          {
            'id': 9,
            'type': 'movie',
            'status': 1,
            'requestedBy': {'id': 1},
            'media': {'tmdbId': 123},
          },
        ],
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('Private title'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 768.0, 1440.0]) {
    testWidgets('request controls fit at ${width.toInt()}px and 200 percent text', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final account = _Account(
        _client((request) async {
          if (request.url.path.endsWith('/request')) {
            return _json({
              'pageInfo': {'pages': 1},
              'results': [
                for (final id in [1, 2])
                  {
                    'type': 'movie',
                    'status': id == 1 ? 2 : 5,
                    'requestedBy': {'id': 1},
                    'media': {'tmdbId': id, 'status': id == 1 ? 3 : 5},
                  },
              ],
            });
          }
          final id = int.parse(request.url.pathSegments.last);
          return _json({'id': id, 'title': id == 1 ? 'Requested film' : 'Available film'});
        }),
      );
      addTearDown(account.dispose);
      final capture = GlobalKey();
      await _pump(tester, account, capture: capture);
      final root = Platform.environment['REQUESTS_QA_ROOT'];
      if (root != null) {
        final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = (await tester.runAsync(() => boundary.toImage()))!;
        final bytes = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png)))!;
        await tester.runAsync(
          () => File('$root/requests-${width.toInt()}-200.png').writeAsBytes(bytes.buffer.asUint8List()),
        );
        image.dispose();
      }
      expect(find.text('Audiobooks'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
