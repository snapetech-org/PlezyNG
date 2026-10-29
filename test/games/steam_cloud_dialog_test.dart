import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/games/steam_cloud_client.dart';
import 'package:plezy/i18n/presentation_formats.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/games/steam_cloud_dialog.dart';
import 'package:plezy/services/trackers/oauth_proxy_client.dart';
import 'package:plezy/theme/mono_theme.dart';

void main() {
  testWidgets('Cloud changes require separate authorization and review, with no retry on uncertainty', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final retired = Completer<void>();
    final grant = 'a' * 43;
    const identity = '76561198000000001', name = 'save/slot1.sav';
    var write = false, deletes = 0;
    SteamCloudClient makeClient() => SteamCloudClient(
      baseUri: Uri.parse('https://plezy.test'),
      httpClient: MockClient((r) async {
        if (r.method == 'DELETE') return http.Response('', 204);
        final body = jsonDecode(r.body);
        if (r.url.path.endsWith('/start')) {
          write = body['write'] == true;
          return http.Response(
            jsonEncode({'session': 'b' * 24, 'url': 'https://plezy.test/auth/steam-cloud?state=${'c' * 24}'}),
            200,
          );
        }
        if (body['action'] == 'delete') {
          deletes++;
          return http.Response('{"error":"refresh_required"}', 409);
        }
        return http.Response(
          jsonEncode({
            'appId': 620,
            'steamId': identity,
            'write': write,
            'files': [
              {'name': name, 'size': 3, 'sha': 'a9993e364706816aba3e25717850c26c9cd0d89d', 'modified': 1700000000},
            ],
          }),
          200,
        );
      }),
    );
    final proxy = OAuthProxyClient(
      httpClient: MockClient(
        (_) async => http.Response(jsonEncode({'steamId': identity, 'steamCloudToken': grant}), 200),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.oled),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.7)),
          child: Directionality(textDirection: TextDirection.rtl, child: child!),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => SteamCloudDialog(
                  client: makeClient(),
                  clientFactory: makeClient,
                  proxy: proxy,
                  capabilities: const SteamCloudCapabilities(read: true, write: true),
                  catalog: grant,
                  appId: 620,
                  steamId: identity,
                  isCurrent: () => true,
                  retired: retired.future,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.common.connect));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text(isolateDisplayText(name)), 160);
    expect(find.text(isolateDisplayText(name)), findsOneWidget);
    expect(write, isFalse);
    expect(deletes, 0);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text(t.games.cloudEnableChanges));
    await tester.tap(find.text(t.games.cloudEnableChanges));
    await tester.pumpAndSettle();
    expect(write, isTrue);
    expect(deletes, 0);
    final options = find.byTooltip('${t.common.options}: ${isolateDisplayText(name)}');
    await tester.scrollUntilVisible(options, 160);
    await tester.tap(options);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text(t.common.delete), 100, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text(t.common.delete));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text(t.games.cloudReviewDelete(name: isolateDisplayText(name))), 160);
    expect(deletes, 0);
    await tester.scrollUntilVisible(find.text(t.common.confirm), 160);
    await tester.tap(find.text(t.common.confirm));
    await tester.pumpAndSettle();
    expect(deletes, 1);
    expect(find.text(t.games.cloudRefreshRequired), findsOneWidget);
    expect(find.text(isolateDisplayText(name)), findsNothing);
    expect(find.text(t.common.confirm), findsNothing);
    expect(tester.takeException(), isNull);
    retired.complete();
    await tester.pumpAndSettle();
    expect(find.byType(SteamCloudDialog), findsNothing);
    expect(deletes, 1);
  });
}
