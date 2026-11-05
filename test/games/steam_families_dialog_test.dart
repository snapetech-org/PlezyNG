import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/games/steam_families_client.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/games/steam_families_dialog.dart';
import 'package:plezy/theme/mono_theme.dart';

import 'steam_families_client_test.dart' show familyIdentity, familyStateJson;

class _Families extends SteamFamiliesClient {
  _Families()
    : super(
        catalog: 'a' * 43,
        steamId: familyIdentity,
        baseUri: Uri.parse('https://plezy.test'),
        httpClient: MockClient((_) async => http.Response('', 204)),
      ) {
    authorized = true;
  }
  int commits = 0, retirements = 0;
  @override
  Future<SteamFamilyState> state() async => SteamFamilyState(familyStateJson());
  @override
  Future<SteamFamilyReview> review(SteamFamilyChange change) async =>
      SteamFamilyReview('c' * 43, change, await state());
  @override
  Future<bool> commit(SteamFamilyReview review) async {
    commits++;
    throw const SteamFamiliesUnavailable(refreshRequired: true);
  }

  @override
  Future<void> retire() async {
    retirements++;
    await super.retire();
  }
}

void main() {
  for (final largeRtl in [false, true]) {
    testWidgets('family review and retirement (large RTL: $largeRtl)', (tester) async {
      tester.view.physicalSize = largeRtl ? const Size(320, 720) : const Size(380, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = _Families(), retired = Completer<void>();
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.oled),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(largeRtl ? 2 : 1)),
              child: Directionality(textDirection: largeRtl ? TextDirection.rtl : TextDirection.ltr, child: child!),
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => SteamFamiliesDialog(
                      client: client,
                      appId: 620,
                      isCurrent: () => !retired.isCompleted,
                      retired: retired.future,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      Future<void> reveal(Finder target) async {
        await tester.scrollUntilVisible(
          target,
          100,
          scrollable: find.descendant(of: find.byType(SteamFamiliesDialog), matching: find.byType(Scrollable)).first,
        );
        await tester.pumpAndSettle();
        await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
        await tester.pumpAndSettle();
        expect(target.hitTestable(), findsOneWidget);
      }

      await tester.tap(find.text(t.common.refresh));
      await tester.pumpAndSettle();
      await reveal(find.text(t.games.familyLeave));
      await tester.tap(find.text(t.games.familyLeave));
      await tester.pumpAndSettle();
      expect(client.commits, 0);
      await reveal(find.text(t.common.confirm));
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, t.common.confirm)).onPressed, isNull);
      await reveal(find.text(t.games.familyAcknowledge));
      await tester.tap(find.text(t.games.familyAcknowledge));
      await tester.pumpAndSettle();
      await reveal(find.text(t.common.confirm));
      await tester.tap(find.text(t.common.confirm));
      await tester.pumpAndSettle();
      expect(client.commits, 1);
      expect(find.text(t.games.familyRefreshRequired), findsOneWidget);
      expect(tester.takeException(), isNull);
      retired.complete();
      await tester.pumpAndSettle();
      expect(find.byType(SteamFamiliesDialog), findsNothing);
      expect(client.retirements, greaterThan(0));
      expect(client.commits, 1);
    });
  }
}
