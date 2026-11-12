import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_client.dart';
import 'package:plezy/widgets/music/server_analysis_panel.dart';

import '../../test_helpers/backend_client_fixtures.dart';

http.Response _json(Object value) =>
    http.Response(jsonEncode(value), 200, headers: {'content-type': 'application/json'});

http.Response _tasks() => _json({
  'ButlerTasks': {
    'ButlerTask': [
      {'name': 'MusicAnalysis', 'enabled': false},
      {'name': 'LoudnessAnalysis', 'enabled': true},
    ],
  },
});

http.Response _activities() => _json({
  'MediaContainer': {
    'Activity': [
      {'uuid': 'job', 'title': 'Individual server job', 'subtitle': 'Server album', 'progress': -1},
    ],
  },
});

void main() {
  late AppDatabase database;
  late PlexClient client;
  late List<String> calls;
  late bool current;
  late Future<http.Response> Function(http.Request) response;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(database);
    calls = [];
    current = true;
    response = (request) async {
      if (request.url.path == '/butler') return _tasks();
      if (request.url.path == '/activities') return _activities();
      return http.Response('', request.method == 'POST' ? 202 : 200);
    };
    client =
        testPlexClient(
            serverId: ServerId('server'),
            handler: (request) {
              calls.add('${request.method} ${request.url.path}');
              return response(request);
            },
          )
          ..plexAccountId = 'plex.owner'
          ..plexMusicUserIdentifier = 'owner'
          ..bindMusicHistoryResource(owned: true);
  });
  tearDown(() async {
    client.close();
    await database.close();
  });

  Future<void> mount(WidgetTester tester, {bool largeText = false}) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          builder: largeText
              ? (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                )
              : null,
          home: Scaffold(
            body: SingleChildScrollView(
              child: MusicServerAnalysisPanel(client: client, current: () => current),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> settleRead(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> expand(WidgetTester tester) async {
    await tester.tap(find.text(t.musicTools.serverAnalysis));
    await settleRead(tester);
  }

  Future<void> disposePanel(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets('only an expanded owner panel reads and labels individual server activities', (tester) async {
    await mount(tester);
    expect(calls, isEmpty);
    await expand(tester);
    expect(calls, ['GET /butler', 'GET /activities']);
    expect(find.text(t.musicTools.serverAnalysisScope), findsOneWidget);
    expect(find.text('Individual server job'), findsOneWidget);
    final progress = tester.widgetList<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(progress.single.value, isNull);
    expect(find.text(t.musicTools.sonicAnalysis), findsOneWidget);
    await disposePanel(tester);
  });

  testWidgets('an unverified owner has no analysis panel or requests', (tester) async {
    client.bindMusicHistoryResource(owned: false);
    await mount(tester);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(calls, isEmpty);
    await disposePanel(tester);
  });

  testWidgets('analysis starts only after explicit confirmation of the server-wide scope', (tester) async {
    await mount(tester);
    await expand(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, t.libraries.analyze).first);
    await settleRead(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(calls.where((c) => c.startsWith('POST')), isEmpty);
    expect(find.text(t.musicTools.serverAnalysisScope), findsNWidgets(2));
    await tester.tap(find.widgetWithText(TextButton, t.libraries.analyze));
    await settleRead(tester);
    expect(calls.where((c) => c.startsWith('POST')), ['POST /butler/MusicAnalysis']);
    expect(find.text(t.musicTools.loudnessRequested), findsOneWidget);
    await disposePanel(tester);
  });

  testWidgets('stopping a named task also requires server-wide confirmation', (tester) async {
    await mount(tester);
    await expand(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, t.common.cancel).first);
    await settleRead(tester);
    expect(calls.where((call) => call.startsWith('DELETE')), isEmpty);
    await tester.tap(find.widgetWithText(TextButton, t.common.confirm));
    await settleRead(tester);
    expect(calls.where((call) => call.startsWith('DELETE')), ['DELETE /butler/MusicAnalysis']);
    expect(find.text(t.musicTools.loudnessRequested), findsOneWidget);
    await disposePanel(tester);
  });

  testWidgets('an account retired while confirmation is open cannot send a task', (tester) async {
    await mount(tester);
    await expand(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, t.libraries.analyze).first);
    await settleRead(tester);
    client.plexMusicUserIdentifier = 'replacement';
    await tester.tap(find.widgetWithText(TextButton, t.libraries.analyze));
    await settleRead(tester);
    expect(calls.where((c) => c.startsWith('POST') || c.startsWith('DELETE')), isEmpty);
    expect(find.text(t.musicTools.loudnessRequested), findsNothing);
    await disposePanel(tester);
  });

  testWidgets('dismissing confirmation sends no write', (tester) async {
    await mount(tester);
    await expand(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, t.libraries.analyze).first);
    await settleRead(tester);
    await tester.tap(find.widgetWithText(TextButton, t.common.cancel));
    await settleRead(tester);
    expect(calls, ['GET /butler', 'GET /activities']);
    await disposePanel(tester);
  });

  testWidgets('failed activity reads show an error instead of an empty completed set', (tester) async {
    response = (request) async => request.url.path == '/butler' ? _tasks() : http.Response('{}', 403);
    await mount(tester);
    await expand(tester);
    expect(find.text(t.musicExperience.error), findsOneWidget);
    expect(find.text(t.messages.noItemsAvailable), findsNothing);
    expect(find.text(t.musicTools.loudnessRequested), findsNothing);
    await disposePanel(tester);
  });

  testWidgets('background and collapsed panels stop polling and resume refreshes', (tester) async {
    await mount(tester);
    await expand(tester);
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 11));
    expect(calls.length, 2);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settleRead(tester);
    expect(calls.length, 4);
    await tester.tap(find.text(t.musicTools.serverAnalysis));
    await tester.pump(const Duration(seconds: 11));
    expect(calls.length, 4);
    await disposePanel(tester);
  });

  testWidgets('a collapsed in-flight response cannot expose retired activities', (tester) async {
    final entered = Completer<void>(), pending = Completer<http.Response>();
    response = (request) async {
      if (request.url.path == '/butler') {
        if (!entered.isCompleted) entered.complete();
        return pending.future;
      }
      return _activities();
    };
    await mount(tester);
    await tester.tap(find.text(t.musicTools.serverAnalysis));
    await settleRead(tester);
    expect(entered.isCompleted, isTrue);
    await tester.tap(find.text(t.musicTools.serverAnalysis));
    pending.complete(_tasks());
    await settleRead(tester);
    expect(calls, ['GET /butler']);
    expect(find.text('Individual server job'), findsNothing);
    await disposePanel(tester);
  });

  testWidgets('server controls fit 320px at 200 percent text', (tester) async {
    tester.view.physicalSize = const Size(320, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, largeText: true);
    await expand(tester);
    expect(tester.takeException(), isNull);
    await disposePanel(tester);
  });
}
