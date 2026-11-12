import 'package:drift/native.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/music/music_experience.dart';
import 'package:plezy/services/music/music_driving_routes.dart';
import 'package:plezy/services/music/music_library_store.dart';
import 'package:plezy/services/music/music_system_audio_routes.dart';
import 'package:plezy/services/music/music_background_frames.dart';
import 'music_system_audio_routes_test.dart' show route;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/services/music/music_car_host.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/screens/music/music_driving_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:provider/provider.dart';
import '../../test_helpers/media_items.dart';
import '../../test_helpers/stub_music_playback_service.dart';
import '../../test_helpers/prefs.dart';

class Profiles extends ChangeNotifier implements ActiveProfileProvider {
  String id = 'one';
  @override
  String get activeId => id;
  bool binding = false, succeeded = true;
  @override
  bool get isBinding => binding;
  @override
  bool get lastBindingSucceeded => succeeded;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Experience extends ChangeNotifier implements MusicExperience {
  _Experience(this.drivingRoutes);
  @override
  final MusicDrivingRoutes drivingRoutes;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Music extends StubMusicPlaybackService {
  final tracks = [
    testMediaItem(id: 'a', serverId: 'server', kind: MediaKind.track),
    testMediaItem(id: 'b', serverId: 'server', kind: MediaKind.track),
  ];
  int? jumped;
  int pauses = 0;
  @override
  List<MediaItem> get queue => tracks;
  @override
  int get currentIndex => 0;
  @override
  Future<void> jumpTo(int index) async {
    jumped = index;
  }

  @override
  Future<void> pause() async {
    pauses++;
  }

  void edit() {
    tracks.removeLast();
    notifyListeners();
  }
}

class CatalogDownloads extends ChangeNotifier implements DownloadProvider {
  List<MediaItem> tracks = [];
  String? artworkPath;
  @override
  String? getArtworkLocalPath(ServerId serverId, String? artworkPath) => this.artworkPath;

  @override
  List<MediaItem> get downloadedTracks => tracks;
  void publish(List<MediaItem> value) {
    tracks = value;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const codec = StandardMethodCodec();
  const channel = MethodChannel('com.pleazyng/music_car');
  Future<dynamic> native(String method, [Object? arguments]) async {
    final result = Completer<dynamic>();
    unawaited(
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(MethodCall(method, arguments)),
        (reply) {
          try {
            result.complete(codec.decodeEnvelope(reply!));
          } catch (e) {
            result.completeError(e);
          }
        },
      ),
    );
    return result.future;
  }

  Future<void> mount(
    WidgetTester tester,
    Music music,
    Profiles profiles, {
    CatalogDownloads? downloads,
    MusicDrivingRoutes? drivingRoutes,
    void Function(MethodCall)? onNative,
  }) async {
    final navigator = GlobalKey<NavigatorState>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      onNative?.call(call);
      return null;
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MusicPlaybackService>.value(value: music),
          ChangeNotifierProvider<ActiveProfileProvider>.value(value: profiles),
          if (downloads != null) ChangeNotifierProvider<DownloadProvider>.value(value: downloads),
          if (drivingRoutes != null) ChangeNotifierProvider<MusicExperience>(create: (_) => _Experience(drivingRoutes)),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          home: MusicCarHost(navigatorKey: navigator, child: const SizedBox()),
        ),
      ),
    );
    await tester.pump();
  }

  for (final revokeDownload in [false, true]) {
    testWidgets('opaque artwork retires on download removal=$revokeDownload and queue changes', (tester) async {
      final directory = (await tester.runAsync(() => Directory.systemTemp.createTemp('pleazyng-car-artwork-')))!;
      addTearDown(() => directory.delete(recursive: true));
      final image = File('${directory.path}/art.png');
      final bytes = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(
          recorder,
        ).drawRect(const ui.Rect.fromLTWH(0, 0, 2, 2), ui.Paint()..color = const ui.Color(0xff00ff00));
        final picture = recorder.endRecording();
        final decoded = await picture.toImage(2, 2);
        final data = await decoded.toByteData(format: ui.ImageByteFormat.png);
        decoded.dispose();
        picture.dispose();
        return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      });
      await tester.runAsync(() => image.writeAsBytes(bytes!));
      final music = Music();
      music.tracks[0] = testMediaItem(
        id: 'a',
        serverId: 'server',
        kind: MediaKind.track,
        thumbPath: '/private/artwork',
      );
      final downloads = CatalogDownloads()
        ..tracks = [music.tracks.first]
        ..artworkPath = image.path;
      await mount(tester, music, Profiles(), downloads: downloads);
      final rows = await native('browse', {'id': 'queue'}) as List;
      final row = rows.first as Map;
      expect(row['artwork'], isTrue);
      expect(jsonEncode(rows), isNot(contains('/private/artwork')));
      expect(jsonEncode(rows), isNot(contains(image.path)));
      final result = await tester.runAsync(() async => await native('artwork', {'id': row['id'], 'size': 96}));
      expect(result, isA<Uint8List>());
      expect((result as Uint8List).length, lessThan(512 * 1024));
      if (revokeDownload) {
        downloads.publish([]);
      } else {
        music.edit();
      }
      await tester.pump();
      expect(await native('artwork', {'id': row['id'], 'size': 96}), isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('native artwork rejects arbitrary paths missing rows and unsupported sizes', (tester) async {
    await mount(tester, Music(), Profiles());
    for (final args in [
      {'id': 'https://server.invalid/secret', 'size': 96},
      {'id': '../private', 'size': 96},
      {'id': 'queue:1:0', 'size': 10000},
      {'id': 'queue:1:0', 'size': 96.0},
    ]) {
      expect(await native('artwork', args), isNull);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('widget transport is bound to the exact profile scope and queue revision', (tester) async {
    final calls = <MethodCall>[];
    final music = Music(), profiles = Profiles();
    await mount(tester, music, profiles, onNative: calls.add);
    final snapshot = Map<String, dynamic>.from(calls.lastWhere((call) => call.method == 'snapshot').arguments as Map);
    expect((snapshot['labels'] as Map)['pause'], isNotEmpty);
    await native('transport', {'scope': snapshot['scope'], 'revision': snapshot['revision'], 'command': 'pause'});
    expect(music.pauses, 1);
    await expectLater(
      native('transport', {'scope': 'another-profile', 'revision': snapshot['revision'], 'command': 'pause'}),
      throwsA(isA<PlatformException>()),
    );
    music.edit();
    await tester.pump();
    await expectLater(
      native('transport', {'scope': snapshot['scope'], 'revision': snapshot['revision'], 'command': 'pause'}),
      throwsA(isA<PlatformException>()),
    );
    profiles.id = 'other';
    final latest = Map<String, dynamic>.from(calls.lastWhere((call) => call.method == 'snapshot').arguments as Map);
    await expectLater(
      native('transport', {'scope': latest['scope'], 'revision': latest['revision'], 'command': 'pause'}),
      throwsA(isA<PlatformException>()),
    );
    expect(music.pauses, 1);
  });

  testWidgets('projection enters driving by default, respects opt-out and never starts audio', (tester) async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    final settings = await SettingsService.getInstance();
    final music = Music(), profiles = Profiles();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await mount(tester, music, profiles);
    await native('connection', {'connected': true});
    await tester.pumpAndSettle();
    expect(find.byType(MusicDrivingScreen), findsOneWidget);
    expect(music.jumped, isNull);
    await native('connection', {'connected': false});
    await tester.pumpAndSettle();
    expect(find.byType(MusicDrivingScreen), findsNothing);
    expect(music.pauses, 1);
    await settings.write(SettingsService.musicAutoDriving, false);
    await native('connection', {'connected': true});
    await tester.pumpAndSettle();
    expect(find.byType(MusicDrivingScreen), findsNothing);
    expect(music.jumped, isNull);
    await tester.pumpWidget(const SizedBox());
    music.dispose();
    profiles.dispose();
  });

  testWidgets('native queue rows contain no URLs and reject edits that changed their indices', (tester) async {
    final music = Music(), profiles = Profiles();
    await mount(tester, music, profiles);
    final rows = await native('browse', {'id': 'queue'}) as List;
    final id = (rows.last as Map)['id'];
    expect(id, startsWith('queue:'));
    expect((rows.first as Map).keys, isNot(contains('url')));
    music.edit();
    await tester.pump();
    await expectLater(native('playItem', {'id': id}), throwsA(isA<PlatformException>()));
    expect(music.jumped, isNull);
  });
  testWidgets('profile replacement invalidates native requests and attachment never starts audio', (tester) async {
    final music = Music(), profiles = Profiles();
    await mount(tester, music, profiles);
    await native('connection', {'connected': true});
    expect(music.jumped, isNull);
    await native('connection', {'connected': false});
    expect(music.pauses, 1);
    profiles.id = 'two';
    await expectLater(native('browse', {'id': 'queue'}), throwsA(isA<PlatformException>()));
  });
  testWidgets('unmount clears native catalog even after the active profile changed', (tester) async {
    final music = Music(), profiles = Profiles();
    await mount(tester, music, profiles);
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    profiles.id = 'two';
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(calls, contains('close'));
  });
  testWidgets('large queues remain browsable through bounded native pages', (tester) async {
    final music = Music(), profiles = Profiles();
    music.tracks.addAll(
      List.generate(205, (i) => testMediaItem(id: 'extra$i', serverId: 'server', kind: MediaKind.track)),
    );
    await mount(tester, music, profiles);
    var rows = await native('browse', {'id': 'queue'}) as List;
    final seen = <String>[];
    while (true) {
      expect(rows.length, lessThanOrEqualTo(100));
      seen.addAll(rows.where((row) => (row as Map)['playable'] == true).map((row) => row['id'] as String));
      final more = rows.where((row) => (row as Map)['playable'] == false).toList();
      if (more.isEmpty) break;
      rows = await native('browse', {'id': more.single['id']}) as List;
    }
    expect(seen.toSet(), hasLength(207));
    expect(seen, hasLength(207));
  });
  testWidgets('native catalogs refresh for membership changes, not download progress', (tester) async {
    final music = Music(), profiles = Profiles(), downloads = CatalogDownloads();
    await mount(tester, music, profiles, downloads: downloads);
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    downloads.publish(music.tracks);
    await tester.pump();
    expect(calls.where((call) => call == 'catalogChanged'), hasLength(1));
    calls.clear();
    downloads.publish(music.tracks);
    await tester.pump();
    expect(calls, isEmpty);
    profiles.id = 'other';
    downloads.publish([]);
    await tester.pump();
    expect(calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    music.dispose();
    profiles.dispose();
  });

  Future<void> bluetoothScenario(
    WidgetTester tester,
    Future<void> Function(MusicDrivingRoutes, Music, Profiles, Future<void> Function(Object)) body,
  ) async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    late AppDatabase database;
    late MusicDrivingRoutes preferences;
    await tester.runAsync(() async {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      preferences = MusicDrivingRoutes(MusicLibraryStore(database, 'one'));
      await preferences.ready;
      await preferences.select(
        platform: 'ios',
        output: const MusicSystemAudioOutput(
          id: 'stable-system-id',
          name: 'Car',
          type: 'BluetoothA2DPOutput',
          bluetooth: true,
          channels: 2,
        ),
        current: () => true,
      );
    });
    const methods = MethodChannel('com.pleazyng/music_audio_route');
    const events = MethodChannel('com.pleazyng/music_audio_route/events');
    final binding = tester.binding, messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (_) async => route());
    messenger.setMockMethodCallHandler(events, (_) async => null);
    Future<void> emit(Object data) async {
      binding.channelBuffers.push(events.name, codec.encodeSuccessEnvelope(data), (_) {});
      await tester.pumpAndSettle();
    }

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final music = Music(), profiles = Profiles();
    try {
      await body(preferences, music, profiles, emit);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(events, null);
      preferences.dispose();
      music.dispose();
      profiles.dispose();
      await tester.runAsync(database.close);
      SettingsService.resetForTesting();
    }
  }

  testWidgets('selected Bluetooth opens driving once without projection or playback entitlement', (tester) async {
    await bluetoothScenario(tester, (preferences, music, profiles, emit) async {
      await mount(tester, music, profiles, drivingRoutes: preferences);
      await tester.pumpAndSettle();
      expect(find.byType(MusicDrivingScreen), findsOneWidget);
      expect(MusicBackgroundFrames.carConnected, isFalse);
      expect(music.pauses, 0);
      Navigator.of(tester.element(find.byType(MusicDrivingScreen))).pop();
      await tester.pumpAndSettle();
      await emit(route());
      expect(
        find.byType(MusicDrivingScreen),
        findsNothing,
        reason: 'A repeat snapshot must respect a manually dismissed automatic view',
      );
      final disconnected = route()..['outputs'] = <Object>[];
      await emit(disconnected);
      await emit(route());
      expect(find.byType(MusicDrivingScreen), findsOneWidget);
      await emit(disconnected);
      expect(find.byType(MusicDrivingScreen), findsNothing);
      expect(music.pauses, 0, reason: 'Bluetooth UI changes cannot issue a remote/group pause');
    });
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('Bluetooth driving respects profile binding and an unsuccessful PIN result', (tester) async {
    await bluetoothScenario(tester, (preferences, music, profiles, emit) async {
      profiles.binding = true;
      await mount(tester, music, profiles, drivingRoutes: preferences);
      await tester.pumpAndSettle();
      expect(find.byType(MusicDrivingScreen), findsNothing);
      profiles.binding = false;
      profiles.succeeded = false;
      profiles.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(MusicDrivingScreen), findsNothing);
      profiles.succeeded = true;
      profiles.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(MusicDrivingScreen), findsOneWidget);
    });
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('Bluetooth driving respects the automatic-entry master preference', (tester) async {
    await bluetoothScenario(tester, (preferences, music, profiles, emit) async {
      await SettingsService.instance.write(SettingsService.musicAutoDriving, false);
      await mount(tester, music, profiles, drivingRoutes: preferences);
      await tester.pumpAndSettle();
      expect(find.byType(MusicDrivingScreen), findsNothing);
      expect(MusicBackgroundFrames.carConnected, isFalse);
    });
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));
  testWidgets('profile replacement retires only its automatic driving route', (tester) async {
    await bluetoothScenario(tester, (preferences, music, profiles, emit) async {
      await mount(tester, music, profiles, drivingRoutes: preferences);
      await tester.pumpAndSettle();
      expect(find.byType(MusicDrivingScreen), findsOneWidget);
      profiles.id = 'two';
      profiles.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(MusicDrivingScreen), findsNothing);
      await emit(route());
      expect(find.byType(MusicDrivingScreen), findsNothing);
      expect(music.pauses, 0);
    });
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('a late Bluetooth inspection cannot open a retired profile', (tester) async {
    await bluetoothScenario(tester, (preferences, music, profiles, emit) async {
      final response = Completer<Object?>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.pleazyng/music_audio_route'),
        (_) => response.future,
      );
      await mount(tester, music, profiles, drivingRoutes: preferences);
      profiles.id = 'two';
      profiles.notifyListeners();
      response.complete(route());
      await tester.pumpAndSettle();
      expect(find.byType(MusicDrivingScreen), findsNothing);
      expect(MusicBackgroundFrames.carConnected, isFalse);
    });
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('Bluetooth disconnect preserves a manually opened route', (tester) async {
    await bluetoothScenario(tester, (preferences, music, profiles, emit) async {
      await mount(tester, music, profiles, drivingRoutes: preferences);
      await tester.pumpAndSettle();
      final navigator = Navigator.of(tester.element(find.byType(MusicDrivingScreen)));
      navigator.pop();
      await tester.pumpAndSettle();
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Manual driving view'))),
        ),
      );
      await tester.pumpAndSettle();
      await emit(route()..['outputs'] = <Object>[]);
      expect(find.text('Manual driving view'), findsOneWidget);
      expect(music.pauses, 0);
    });
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));
}
