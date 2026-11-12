import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/widgets/music/apple_audio_route_picker.dart';

import '../../services/music/music_system_audio_routes_test.dart' show route;

void main() {
  const methods = MethodChannel('com.pleazyng/music_audio_route');
  const events = MethodChannel('com.pleazyng/music_audio_route/events');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  late bool current;
  late int changed, reads, listens, cancels;
  late Object? snapshot;
  late List<MethodCall> views;
  setUp(() {
    current = true;
    changed = reads = listens = cancels = 0;
    snapshot = route();
    views = [];

    messenger.setMockMethodCallHandler(methods, (call) async {
      expect(call.method, 'snapshot');
      reads++;
      return snapshot;
    });
    messenger.setMockMethodCallHandler(events, (call) async {
      if (call.method == 'listen') listens++;
      if (call.method == 'cancel') cancels++;
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      views.add(call);
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
  });
  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MusicAppleAudioRoutePicker(current: () => current, onChanged: () => changed++),
          ),
        ),
      ),
    ),
  );
  Future<void> disposePicker(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  Future<void> emit(WidgetTester tester, Object value) async {
    final delivered = Completer<void>();
    binding.channelBuffers.push(events.name, const StandardMethodCodec().encodeSuccessEnvelope(value), (_) {
      delivered.complete();
    });
    await tester.pump();
    await delivered.future;
    await tester.pumpAndSettle();
  }

  testWidgets('selected route mounts the real registered OS picker without audio commands', (tester) async {
    await mount(tester);
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(listens, 1);
    expect(find.byType(UiKitView), findsOneWidget);
    expect(find.text('Selected speaker · BluetoothA2DPOutput'), findsOneWidget);
    final create = views.singleWhere((call) => call.method == 'create');
    expect((create.arguments as Map)['viewType'], 'com.pleazyng/music_audio_route_picker');
    expect(changed, 1);
    await disposePicker(tester);
    expect(cancels, 1);
    expect(views.where((call) => call.method == 'dispose').length, 1);
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('native route notifications update selected output and request diagnostics refresh', (tester) async {
    await mount(tester);
    await tester.pumpAndSettle();
    await emit(tester, route(name: 'New system output'));
    expect(find.text('New system output · BluetoothA2DPOutput'), findsOneWidget);
    expect(changed, 2);
    await disposePicker(tester);
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('a newer native notification wins over a delayed inspection', (tester) async {
    final response = Completer<Object?>();
    messenger.setMockMethodCallHandler(methods, (_) => response.future);
    await mount(tester);
    await tester.pump();
    await emit(tester, route(name: 'Current selected route'));
    response.complete(route(name: 'Older inspection'));
    await tester.pumpAndSettle();
    expect(find.text('Current selected route · BluetoothA2DPOutput'), findsOneWidget);
    expect(find.textContaining('Older inspection'), findsNothing);
    expect(changed, 1);
    await disposePicker(tester);
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('background observation retires and resume reads a fresh route', (tester) async {
    await mount(tester);
    await tester.pumpAndSettle();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(cancels, 1);
    snapshot = route(name: 'Resumed route');
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(listens, 2);
    expect(find.text('Resumed route · BluetoothA2DPOutput'), findsOneWidget);
    await disposePicker(tester);
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('retired ownership cannot display a delayed OS route', (tester) async {
    final response = Completer<Object?>();
    messenger.setMockMethodCallHandler(methods, (_) => response.future);
    await mount(tester);
    await tester.pump();
    current = false;
    response.complete(route(name: 'Retired output'));
    await tester.pumpAndSettle();
    expect(find.byType(UiKitView), findsNothing);
    expect(find.textContaining('Retired output'), findsNothing);
    expect(changed, 0);
    await disposePicker(tester);
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('missing and malformed native snapshots do not show a working route picker', (tester) async {
    snapshot = {'version': 1};
    await mount(tester);
    await tester.pumpAndSettle();
    expect(find.byType(UiKitView), findsNothing);
    expect(changed, 0);
    await disposePicker(tester);
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('unsupported desktop does not create an AVPlayer route for an mpv output', (tester) async {
    await mount(tester);
    await tester.pumpAndSettle();
    expect(reads, 0);
    expect(listens, 0);
    expect(find.byType(UiKitView), findsNothing);
    await disposePicker(tester);
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));
}
