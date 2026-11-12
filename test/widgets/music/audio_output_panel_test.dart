import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/music/music_audio_policy.dart';
import 'package:plezy/widgets/music/audio_output_panel.dart';

class _Audio implements MusicAudioControls {
  @override
  MusicAudioPolicy audioPolicy = const MusicAudioPolicy(
    leveling: MusicLeveling.album,
    preampDb: -3,
    bands: [3, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    sampleRate: 96000,
    exclusive: true,
    output: 'alsa/gone',
    prefetchMiB: 128,
  );
  int reads = 0;
  final changes = <MusicAudioPolicy>[];
  Future<Map<String, String>> Function()? read;
  @override
  Future<Map<String, String>> inspectAudioOutput() {
    reads++;
    return read?.call() ?? Future.value({'audio-device': audioPolicy.output, 'audio-out-params/samplerate': '48000'});
  }

  @override
  Future<void> setAudioPolicy(MusicAudioPolicy value) async {
    changes.add(value);
    audioPolicy = value;
  }

  @override
  Future<Map<String, String>> availableAudioOutputs() async => {};
  @override
  Future<MusicAudioPolicy?> outputEqualizer(String output) async => null;
  @override
  Future<void> setOutputEqualizer(String output, MusicAudioPolicy? policy) async {}
}

void main() {
  late _Audio audio;
  late bool current;
  late int automatic;
  setUp(() {
    audio = _Audio();
    current = true;
    automatic = 0;
  });
  Future<void> mount(WidgetTester tester, {bool large = false}) => tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        builder: large
            ? (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              )
            : null,
        home: Scaffold(
          body: SingleChildScrollView(
            child: MusicAudioOutputPanel(audio: audio, current: () => current, onAutomaticOutput: () => automatic++),
          ),
        ),
      ),
    ),
  );
  Future<void> expand(WidgetTester tester) async {
    await tester.tap(find.text(t.musicExperience.signalPath));
    await tester.pumpAndSettle();
  }

  testWidgets('inspection is read-only and starts only on expansion', (tester) async {
    await mount(tester);
    expect(audio.reads, 0);
    await expand(tester);
    expect(find.text('audio-out-params/samplerate: 48000'), findsOneWidget);
    expect(audio.reads, 1);
    expect(audio.changes, isEmpty);
  });
  testWidgets('automatic recovery preserves applied DSP and cache policy', (tester) async {
    await mount(tester);
    await expand(tester);
    final before = audio.audioPolicy.toJson();
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    expect(audio.changes.single.toJson(), {...before, 'output': 'auto', 'exclusive': false, 'sampleRate': 0});
    expect(automatic, 1);
    expect(audio.reads, 2);
    expect(find.text('audio-device: auto'), findsOneWidget);
  });
  testWidgets('unavailable output information cannot trigger a recovery', (tester) async {
    audio.read = () async => {};
    await mount(tester);
    await expand(tester);
    expect(find.text(t.musicExperience.outputUnknown), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed, isNull);
    expect(audio.changes, isEmpty);
  });
  testWidgets('retired inspection cannot publish values or enable recovery', (tester) async {
    final reading = Completer<Map<String, String>>();
    audio.read = () => reading.future;
    await mount(tester);
    await tester.tap(find.text(t.musicExperience.signalPath));
    await tester.pump();
    current = false;
    reading.complete({'audio-device': 'old-profile-device'});
    await tester.pumpAndSettle();
    expect(find.textContaining('old-profile-device'), findsNothing);
    expect(audio.changes, isEmpty);
  });
  testWidgets('failed refresh removes the old report', (tester) async {
    await mount(tester);
    await expand(tester);
    audio.read = () async => throw StateError('Device vanished');
    await tester.tap(find.text(t.common.refresh));
    await tester.pumpAndSettle();
    expect(find.text('audio-out-params/samplerate: 48000'), findsNothing);
    expect(find.text(t.musicExperience.error), findsOneWidget);
  });
  testWidgets('output controls wrap at 320px with 200 percent text', (tester) async {
    tester.view.physicalSize = const Size(320, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, large: true);
    await expand(tester);
    expect(tester.takeException(), isNull);
  });
}
