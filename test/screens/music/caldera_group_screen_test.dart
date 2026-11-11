import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/music/caldera_group_screen.dart';
import 'package:plezy/services/music/caldera_group.dart';
import 'package:plezy/services/music/caldera_audio_source.dart';
import 'package:plezy/services/music/caldera_audio_sink.dart';
import '../../test_helpers/theme.dart';

class _Discovery extends CalderaDiscovery {
  final events = StreamController<List<CalderaNode>>.broadcast(sync: true);
  final entries = [
    CalderaNode(
      id: '11111111-1111-4111-8111-111111111111',
      name: 'Leader',
      address: InternetAddress('192.168.1.30'),
      companionPort: 32500,
      expires: DateTime.now().add(const Duration(minutes: 1)),
    ),
    CalderaNode(
      id: '22222222-2222-4222-8222-222222222222',
      name: 'Speaker',
      address: InternetAddress('192.168.1.31'),
      companionPort: 32500,
      expires: DateTime.now().add(const Duration(minutes: 1)),
    ),
  ];
  @override
  Stream<List<CalderaNode>> get changes => events.stream;
  @override
  List<CalderaNode> get nodes => entries;
  @override
  Future<void> start() async => scheduleMicrotask(() => events.add(entries));
  @override
  void dispose() {
    unawaited(events.close());
    super.dispose();
  }
}

class _Client extends CalderaGroupClient {
  final groups = <List<String>>[];
  final actions = <String>[];
  @override
  Future<CalderaState> state(CalderaNode node, {required bool Function() current}) async {
    if (!current()) throw StateError('Changed source');
    return (
      player: 'native-player',
      title: 'Native track',
      state: 'playing',
      volume: 60,
      position: 1200,
      duration: 60000,
    );
  }

  @override
  Future<void> group(
    CalderaNode leader,
    CalderaState expected,
    List<CalderaNode> sinks, {
    required bool Function() current,
  }) async {
    if (!current()) throw StateError('Changed source');
    groups.add(sinks.map((sink) => sink.id).toList());
  }

  @override
  Future<void> transport(
    CalderaNode node,
    CalderaState expected,
    String action, {
    required bool Function() current,
  }) async {
    if (!current()) throw StateError('Changed source');
    actions.add(action);
  }
}

class _Audio implements NativeMusicGroupControls, NativeMusicGroupSourceControls {
  @override
  bool receivingNativeMusicGroup = false;
  @override
  bool sendingNativeMusicGroup = false;
  final selections = <List<String>>[];
  @override
  Future<void> receiveNativeMusicGroup(CalderaNode leader, {required bool Function() current}) async {
    if (current()) receivingNativeMusicGroup = true;
  }

  @override
  Future<void> sendNativeMusicGroup(List<CalderaNode> sinks, {required bool Function() current}) async {
    if (!current()) return;
    selections.add(sinks.map((node) => node.id).toList());
    sendingNativeMusicGroup = true;
  }

  @override
  Future<void> leaveNativeMusicGroup() async {
    receivingNativeMusicGroup = false;
    sendingNativeMusicGroup = false;
  }
}

void main() {
  testWidgets('native output sends the shared queue to the selected speakers and can release it', (tester) async {
    final discovery = _Discovery(), client = _Client(), audio = _Audio();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [testMonoTokens]),
        home: CalderaGroupScreen(
          current: () => true,
          audio: audio,
          discoveryFactory: () => discovery,
          clientFactory: () => client,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leader').last);
    await tester.pumpAndSettle();
    final speaker = find.widgetWithText(CheckboxListTile, 'Speaker');
    await tester.ensureVisible(speaker);
    await tester.tap(speaker);
    await tester.pumpAndSettle();
    final tile = find.widgetWithText(ListTile, t.musicDevices.playOn);
    await tester.ensureVisible(tile);
    final action = find.descendant(of: tile, matching: find.byType(IconButton));
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(audio.selections.single, discovery.entries.map((node) => node.id));
    expect(audio.sendingNativeMusicGroup, isTrue);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(audio.sendingNativeMusicGroup, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final narrow in [false, true]) {
    testWidgets('native groups select source and sinks with transport at ${narrow ? '320px/200%' : 'normal size'}', (
      tester,
    ) async {
      LocaleSettings.setLocaleSync(AppLocale.en);
      tester.view.physicalSize = narrow ? const Size(320, 800) : const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final discovery = _Discovery();
      final client = _Client();
      var current = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: const [testMonoTokens]),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(narrow ? 2 : 1)),
            child: child!,
          ),
          home: CalderaGroupScreen(
            current: () => current,
            discoveryFactory: () => discovery,
            clientFactory: () => client,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leader').last);
      await tester.pumpAndSettle();
      expect(find.text('Native track'), findsOneWidget);
      final speaker = find.widgetWithText(CheckboxListTile, 'Speaker');
      await tester.ensureVisible(speaker);
      await tester.tap(speaker);
      await tester.pumpAndSettle();
      final save = find.widgetWithText(FilledButton, t.common.save);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(client.groups.single, [discovery.entries.last.id]);
      final next = find.byTooltip(t.music.nextTrack);
      await tester.ensureVisible(next);
      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(client.actions, ['skipNext']);
      current = false;
      await tester.tap(next);
      await tester.pump();
      expect(client.actions, ['skipNext']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
