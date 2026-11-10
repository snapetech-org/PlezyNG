import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/catalog/catalog_item.dart';
import 'package:plezy/models/catalog/catalog_metadata.dart';
import 'package:plezy/models/seerr/seerr_session.dart';
import 'package:plezy/providers/catalog_sources_provider.dart';
import 'package:plezy/services/catalog/seerr_catalog_source.dart';
import 'package:plezy/services/seerr/seerr_client.dart';
import 'package:plezy/services/seerr/seerr_constants.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/external_url.dart';
import 'package:plezy/widgets/catalog_context_menu.dart';
import 'package:provider/provider.dart';

const _item = CatalogItem(
  source: CatalogSourceId.trakt,
  kind: MediaKind.movie,
  title: 'Menu Movie',
  ids: CatalogItemIds(tmdb: 61),
  trailerUrl: 'https://youtu.be/dQw4w9WgXcQ',
  links: [CatalogLink(label: 'StreamCo', url: 'https://example.com/watch', isStreaming: true)],
);

class _SeerrMenuSources extends CatalogSourcesProvider {
  _SeerrMenuSources(this.seerr);
  final SeerrCatalogSource seerr;

  @override
  SeerrCatalogSource get seerrSource => seerr;
}

Future<void> _openMenu(WidgetTester tester, {SeerrCatalogSource? seerr}) async {
  final sources = seerr == null ? null : _SeerrMenuSources(seerr);
  if (sources != null) addTearDown(sources.dispose);
  await tester.pumpWidget(
    TranslationProvider(
      child: sources == null
          ? _menuApp()
          : ChangeNotifierProvider<CatalogSourcesProvider>.value(value: sources, child: _menuApp()),
    ),
  );
  await tester.tap(find.text('Open menu'));
  await tester.pumpAndSettle();
}

Widget _menuApp() => MaterialApp(
  theme: monoTheme(MonoPalette.dark),
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => unawaited(showCatalogItemMenu(context, _item, position: const Offset(10, 10))),
        child: const Text('Open menu'),
      ),
    ),
  ),
);

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  testWidgets('catalog menu offers a request and a separate alert-off action', (tester) async {
    var alertDeletes = 0;
    final client = SeerrClient(
      const SeerrSession(
        baseUrl: 'https://seerr.example.com',
        method: SeerrAuthMethod.local,
        identifier: 'alice',
        secret: 'pw',
        cookie: 'session',
        userId: 1,
        permissions: SeerrPermission.request,
        displayName: 'Alice',
        instanceLabel: 'Seerr',
        createdAt: 0,
      ),
      onSessionInvalidated: () {},
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/v1/request/intent/state') {
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'mediaType': 'movie',
                  'tmdbId': 61,
                  'status': 2,
                  'status4k': 5,
                  'standard': {'own': null, 'other': null},
                  'fourK': {'own': null, 'other': null},
                  'canRequest': true,
                  'canRequest4k': false,
                  'quickRequest': false,
                  'subscribed': true,
                  'subscriptionScope': {'is4k': true, 'seasonNumber': null},
                  'seasons': <Object>[],
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'DELETE' && request.url.path == '/api/v1/user/1/availability-subscriptions/movie/61') {
          alertDeletes++;
          return http.Response('{}', 200, headers: {'content-type': 'application/json'});
        }
        fail('Unexpected Seerr request: ${request.method} ${request.url.path}');
      }),
    );
    addTearDown(client.dispose);
    await _openMenu(tester, seerr: SeerrCatalogSource(client));

    expect(find.text(t.seerr.request), findsOneWidget);
    expect(find.text(t.seerr.turnOffAlert), findsOneWidget);
    await tester.tap(find.text(t.seerr.turnOffAlert));
    await tester.pumpAndSettle();
    expect(alertDeletes, 1);
  });

  testWidgets('says so when a link cannot be opened', (tester) async {
    const urlLauncherChannel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(urlLauncherChannel, (call) async => call.method == 'launch' ? false : null);
    addTearDown(() => messenger.setMockMethodCallHandler(urlLauncherChannel, null));

    await _openMenu(tester);
    await tester.tap(find.text('Open on StreamCo'));
    await tester.pumpAndSettle();

    expect(find.text(t.explore.detail.linkUnavailable), findsOneWidget);
  });

  group('tvOS runner', () {
    const handoffChannel = MethodChannel('com.plezy/external_player');
    late bool youTubeInstalled;
    late List<String> opened;

    setUp(() {
      debugTvosRunnerOverride = true;
      youTubeInstalled = true;
      opened = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(handoffChannel, (
        call,
      ) async {
        final url = (call.arguments as Map)['url'] as String;
        switch (call.method) {
          case 'canOpenUrl':
            return url == 'youtube://' && youTubeInstalled;
          case 'openUrl':
            opened.add(url);
            return true;
        }
        return null;
      });
    });

    tearDown(() {
      debugTvosRunnerOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(handoffChannel, null);
    });

    testWidgets('drops site links and hands the trailer to the YouTube app', (tester) async {
      await _openMenu(tester);

      expect(find.text('Open on StreamCo'), findsNothing);
      await tester.tap(find.text(t.explore.detail.watchTrailer));
      await tester.pumpAndSettle();

      expect(opened, ['youtube://www.youtube.com/watch?v=dQw4w9WgXcQ']);
    });

    testWidgets('drops the trailer when the YouTube app is missing', (tester) async {
      youTubeInstalled = false;

      await _openMenu(tester);

      expect(find.text(t.mediaMenu.viewDetails), findsOneWidget);
      expect(find.text(t.explore.detail.watchTrailer), findsNothing);
    });
  });
}
