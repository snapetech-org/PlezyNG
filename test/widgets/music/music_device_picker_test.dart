import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/services/music/music_device_controller.dart';
import 'package:plezy/services/music/music_device_link.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/widgets/music/music_device_picker.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/stub_music_playback_service.dart';

class _Companion extends ChangeNotifier implements CompanionRemoteProvider {
  @override
  bool get isCryptoReady => true;
  @override
  MusicDeviceController? get musicDevices => null;
  @override
  MusicDeviceLink? get pairedMusicDevice => null;
  @override
  bool get musicDeviceBusy => false;
  @override
  String get musicRelayUrl => '';
  @override
  bool get musicRelayEnabled => false;
  @override
  bool get musicRelayConnected => false;
  @override
  Future<void> loadMusicRelayConfiguration() async {}
  @override
  Future<List<DiscoveredHost>> rememberedMusicDevices() async => [];
  @override
  Stream<List<DiscoveredHost>>? discoverMusicDevices() => const Stream.empty();
  @override
  void stopMusicDiscovery() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('Play on remains available while idle at 320px and text scale $scale', (tester) async {
      tester.view.physicalSize = const Size(320, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final companion = _Companion();
      final music = StubMusicPlaybackService();
      addTearDown(companion.dispose);
      addTearDown(music.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<CompanionRemoteProvider>.value(value: companion),
            ChangeNotifierProvider<MusicPlaybackService>.value(value: music),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const Scaffold(body: MusicDeviceButton()),
          ),
        ),
      );
      expect(find.byTooltip(t.musicDevices.playOn), findsOneWidget);
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      expect(find.text(t.musicDevices.thisDevice), findsOneWidget);
      expect(find.text(t.musicDevices.receive), findsOneWidget);
      expect(find.text(t.musicDevices.away), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
