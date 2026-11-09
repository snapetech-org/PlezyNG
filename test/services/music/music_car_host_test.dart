import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/services/music/music_car_host.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:provider/provider.dart';
import '../../test_helpers/media_items.dart';
import '../../test_helpers/stub_music_playback_service.dart';

class Profiles extends ChangeNotifier implements ActiveProfileProvider {
  String id = 'one';
  @override
  String get activeId => id;
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

  Future<void> mount(WidgetTester tester, Music music, Profiles profiles) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => null,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MusicPlaybackService>.value(value: music),
          ChangeNotifierProvider<ActiveProfileProvider>.value(value: profiles),
        ],
        child: MaterialApp(
          home: MusicCarHost(navigatorKey: GlobalKey<NavigatorState>(), child: const SizedBox()),
        ),
      ),
    );
    await tester.pump();
  }

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
}
