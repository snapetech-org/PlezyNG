import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/music/music_driving_routes.dart';
import 'package:plezy/services/music/music_library_store.dart';
import 'package:plezy/widgets/music/driving_routes_picker.dart';

import '../../services/music/music_system_audio_routes_test.dart' show route;

class _Store extends MusicLibraryStore {
  _Store(AppDatabase database) : super(database, 'one');
  Map<String, dynamic>? saved;
  int writes = 0;
  @override
  Future<Map<String, dynamic>?> document(String kind, String id) async => saved;
  @override
  Future<void> saveDocument(String kind, String id, Map<String, dynamic> value) async {
    writes++;
    saved = value;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const methods = MethodChannel('com.pleazyng/music_audio_route');
  const events = MethodChannel('com.pleazyng/music_audio_route/events');
  late AppDatabase database;
  late _Store store;
  late MusicDrivingRoutes preferences;
  late bool current;
  late Object? snapshot;
  late int reads;
  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    store = _Store(database);
    current = true;
    snapshot = route();
    reads = 0;
    messenger.setMockMethodCallHandler(methods, (_) async {
      reads++;
      return snapshot;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
    await database.close();
  });

  Future<void> mount(WidgetTester tester, {double scale = 1}) async {
    preferences = MusicDrivingRoutes(store);
    await preferences.ready;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          builder: (_, child) => MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: MusicDrivingRoutesPicker(routes: preferences, current: () => current),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    preferences.dispose();
  }

  Future<void> emit(WidgetTester tester, Object data) async {
    binding.channelBuffers.push(events.name, const StandardMethodCodec().encodeSuccessEnvelope(data), (_) {});
    await tester.pumpAndSettle();
  }

  final mobile = TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.android});
  testWidgets('only a live selected Bluetooth output can be armed, then removed offline', (tester) async {
    await mount(tester);
    expect(preferences.routes, isEmpty);
    expect(find.byType(CheckboxListTile), findsOneWidget);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(preferences.routes.single.id, 'stable-system-id');
    expect(
      preferences.routes.single.platform,
      Theme.of(tester.element(find.byType(CheckboxListTile))).platform == TargetPlatform.iOS ? 'ios' : 'android',
    );
    expect(store.writes, 1);
    await emit(tester, route()..['outputs'] = <Object>[]);
    expect(find.text('Selected speaker'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isTrue);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(preferences.routes, isEmpty);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(store.writes, 2);
    await close(tester);
  }, variant: mobile);

  testWidgets('non-Bluetooth selected routes cannot become automatic driving triggers', (tester) async {
    snapshot = route()
      ..['outputs'] = [
        {'id': 'built-in', 'name': 'Speaker', 'type': 'speaker', 'bluetooth': false, 'channels': 2},
      ];
    await mount(tester);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(store.writes, 0);
    await close(tester);
  }, variant: mobile);

  testWidgets('a stale checkbox callback rechecks native selection and profile ownership', (tester) async {
    await mount(tester);
    final stale = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged!;
    await emit(tester, route()..['outputs'] = <Object>[]);
    stale(true);
    await tester.pumpAndSettle();
    expect(store.writes, 0);
    expect(find.text(t.musicExperience.error), findsOneWidget);
    await emit(tester, route());
    final retired = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged!;
    current = false;
    retired(true);
    await tester.pumpAndSettle();
    expect(store.writes, 0);
    await close(tester);
  }, variant: mobile);

  testWidgets('unreadable saved routes require an explicit reset before selecting', (tester) async {
    store.saved = {'version': 2, 'routes': []};
    await mount(tester);
    expect(find.text(t.musicExperience.error), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged, isNull);
    await tester.tap(find.text(t.common.reset));
    await tester.pumpAndSettle();
    expect(preferences.available, isTrue);
    expect(store.writes, 1);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(store.writes, 2);
    await close(tester);
  }, variant: mobile);

  testWidgets('the route selector fits a narrow viewport with 200 percent text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    snapshot = route(name: 'Car Bluetooth with a long system output name');
    await mount(tester, scale: 2);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(preferences.routes, hasLength(1));
    expect(tester.takeException(), isNull);
    await close(tester);
  }, variant: mobile);

  testWidgets('unsupported desktop does not observe routes or offer automatic entry', (tester) async {
    await mount(tester);
    expect(reads, 0);
    expect(find.byType(CheckboxListTile), findsNothing);
    await close(tester);
  }, variant: TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('a delayed native snapshot cannot create a trigger after owner retirement', (tester) async {
    final response = Completer<Object?>();
    messenger.setMockMethodCallHandler(methods, (_) => response.future);
    await mount(tester);
    current = false;
    response.complete(route());
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(store.writes, 0);
    await close(tester);
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));
}
