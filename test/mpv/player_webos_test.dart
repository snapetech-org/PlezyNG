import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/platform/player_webos.dart';
import 'package:video_player_drm/video_player_platform_interface.dart' as native;

import '../fixtures/pgs_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final inheritedHttpOverrides = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = inheritedHttpOverrides);

  test('failed native creation releases disposal and permits the next open', () async {
    final backend = _LGPlayer()..failCreate = true;
    native.VideoPlayerPlatform.instance = backend;
    final player = PlayerWebOS();
    await expectLater(
      player.open(Media('/movie.mkv')).timeout(const Duration(seconds: 1)),
      throwsA(isA<PlatformException>()),
    );
    backend.failCreate = false;
    await player.open(Media('/retry.mkv')).timeout(const Duration(seconds: 1));
    expect(player.state.playing, isTrue);
    await player.dispose().timeout(const Duration(seconds: 1));
    expect(backend.disposed, [1]);
  });
  test('null native player id fails without disposing an unallocated player', () async {
    final backend = _LGPlayer()..nullCreate = true;
    native.VideoPlayerPlatform.instance = backend;
    final player = PlayerWebOS();
    await expectLater(player.open(Media('/movie.mkv')), throwsA(isA<PlatformException>()));
    await player.dispose().timeout(const Duration(seconds: 1));
    expect(backend.disposed, isEmpty);
  });

  test('native creation waits for platform initialization', () async {
    final backend = _LGPlayer()..initGate = Completer<void>();
    native.VideoPlayerPlatform.instance = backend;
    final player = PlayerWebOS();
    final opening = player.open(Media('/movie.mkv'));
    await backend.initializing.future;
    expect(backend.sources, isEmpty);
    backend.initGate!.complete();
    await opening;
    expect(backend.sources, hasLength(1));
    await player.dispose();
  });

  test('opaque authenticated HLS URL retains NDL transport hint', () async {
    final backend = _LGPlayer();
    native.VideoPlayerPlatform.instance = backend;
    final player = PlayerWebOS();
    await player.open(Media('https://server.test/start.m3u8?X-Plex-Token=private-token'));
    final source = backend.sources.single;
    expect(Uri.parse(source.uri!).host, '127.0.0.1');
    expect(source.uri, isNot(contains('private-token')));
    expect(source.httpHeaders, isEmpty);
    expect(source.formatHint, native.VideoFormat.hls);
    await player.dispose();
  });

  for (final scenario in [
    (expected: true, native: <Map<String, dynamic>>[], rejected: true),
    (expected: false, native: <Map<String, dynamic>>[], rejected: false),
    (
      expected: true,
      native: <Map<String, dynamic>>[
        {'language': 'eng', 'trackId': 0},
      ],
      rejected: false,
    ),
    (expected: true, native: null, rejected: false),
  ]) {
    test('known source audio=${scenario.expected}, native=${scenario.native}: reject=${scenario.rejected}', () async {
      final backend = _LGPlayer()..audioTracks = scenario.native;
      native.VideoPlayerPlatform.instance = backend;
      final player = PlayerWebOS();
      final errors = <PlayerError>[];
      final subscription = player.streams.error.listen(errors.add);
      await player.setProperty('webos-source-has-audio', scenario.expected ? 'yes' : 'no');
      final opening = player.open(Media('/movie.mkv'));
      if (scenario.rejected) {
        await expectLater(opening, throwsA(isA<PlatformException>()));
        await Future<void>.delayed(Duration.zero);
        expect(errors.single.cause, PlayerError.audioCodecUnsupported);
      } else {
        await opening;
        expect(errors, isEmpty);
        expect(player.state.playing, isTrue);
      }
      await subscription.cancel();
      await player.dispose();
    });
  }

  test('only unsupported native audio gets a conversion cause', () async {
    final backend = _LGPlayer()
      ..streamError = PlatformException(code: 'media-error', message: 'Unsupported audio codec DTS');
    native.VideoPlayerPlatform.instance = backend;
    final player = PlayerWebOS();
    final errors = <PlayerError>[];
    final subscription = player.streams.error.listen(errors.add);
    await expectLater(player.open(Media('/movie.mkv')), throwsA(isA<PlatformException>()));
    await Future<void>.delayed(Duration.zero);
    expect(errors.single.cause, PlayerError.audioCodecUnsupported);
    await subscription.cancel();
    await player.dispose();
  });

  test('native initialization error reaches caller, releases source and permits retry', () async {
    final backend = _LGPlayer()
      ..streamError = PlatformException(
        code: '-2',
        message: 'invalid window https://server.test/r/private-capability?token=private-token',
      );
    native.VideoPlayerPlatform.instance = backend;
    final player = PlayerWebOS();
    await expectLater(
      player.open(Media('/movie.mkv')).timeout(const Duration(seconds: 1)),
      throwsA(
        isA<PlatformException>()
            .having((e) => e.code, 'native code', '-2')
            .having((e) => e.toString(), 'safe description', isNot(contains('private-'))),
      ),
    );
    expect(backend.disposed, [1]);
    expect(player.state.playing, isFalse);
    backend.streamError = null;
    await player.open(Media('/retry.mkv'));
    expect(player.state.playing, isTrue);
    await player.dispose();
    expect(backend.disposed, [1, 2]);
  });

  test('local PGS follows media position, delay, visibility and subtitle-off', () async {
    final backend = _LGPlayer()..position = const Duration(seconds: 1);
    native.VideoPlayerPlatform.instance = backend;
    final player = PlayerWebOS();
    final directory = await Directory.systemTemp.createTemp('pleazyng-pgs-test-');
    addTearDown(() async {
      await player.dispose();
      await directory.delete(recursive: true);
    });
    final file = await File('${directory.path}/synthetic.sup').writeAsBytes(syntheticPgsFixture());
    await player.open(Media('/movie.mkv'));
    await player.selectSubtitleTrack(SubtitleTrack.uri(file.uri.toString(), codec: 'pgs'));
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(player.pgsCue.value, isNotNull);
    expect(player.pgsCue.value!.rasterize().single.rgba.sublist(0, 4), [255, 255, 255, 128]);
    expect(backend.subtitleEnabled.last, isFalse);
    await player.setProperty('sub-delay', '0.5');
    expect(player.pgsCue.value, isNull);
    await player.setProperty('sub-delay', '0');
    expect(player.pgsCue.value, isNotNull);
    await player.setProperty('sub-visibility', 'no');
    expect(player.pgsCue.value, isNull);
    await player.setProperty('sub-visibility', 'yes');
    expect(player.pgsCue.value, isNotNull);
    await player.selectSubtitleTrack(SubtitleTrack.off);
    expect(player.pgsCue.value, isNull);
  });

  test('PGS sidecar carries same-origin media authentication without reopening video', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String?>[];
    server.listen((request) async {
      requests.add(request.headers.value(HttpHeaders.authorizationHeader));
      request.response.add(syntheticPgsFixture());
      await request.response.close();
    });
    final backend = _LGPlayer()..position = const Duration(seconds: 1);
    native.VideoPlayerPlatform.instance = backend;
    final player = PlayerWebOS();
    addTearDown(() async {
      await player.dispose();
      await server.close(force: true);
    });
    final base = 'http://${server.address.address}:${server.port}';
    await player.open(Media('$base/movie.mkv', headers: {'Authorization': 'private-test-header'}));
    await player.selectSubtitleTrack(SubtitleTrack.uri('$base/captions.sup?token=private-test-token', codec: 'pgs'));
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(requests, ['private-test-header']);
    expect(player.pgsCue.value, isNotNull);
    expect(backend.sources, hasLength(1));
  });

  test('refuses subtitle redirects to a different origin without exposing the signed URL', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(HttpHeaders.locationHeader, 'http://127.0.0.1:1/other?token=private-test-token');
      await request.response.close();
    });
    native.VideoPlayerPlatform.instance = _LGPlayer();
    final player = PlayerWebOS();
    addTearDown(() async {
      await player.dispose();
      await server.close(force: true);
    });
    await player.open(Media('/movie.mkv'));
    await expectLater(
      player.selectSubtitleTrack(SubtitleTrack.uri('http://127.0.0.1:${server.port}/caption.sup', codec: 'pgs')),
      throwsA(
        isA<FormatException>().having(
          (error) => error.toString(),
          'redacted message',
          isNot(contains('private-test-token')),
        ),
      ),
    );
    expect(player.pgsCue.value, isNull);
  });

  test('subtitle-off wins over a late PGS download', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requested = Completer<void>();
    final release = Completer<void>();
    server.listen((request) async {
      requested.complete();
      await release.future;
      request.response.add(syntheticPgsFixture());
      await request.response.close();
    });
    native.VideoPlayerPlatform.instance = _LGPlayer()..position = const Duration(seconds: 1);
    final player = PlayerWebOS();
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await player.dispose();
      await server.close(force: true);
    });
    await player.open(Media('/movie.mkv'));
    final selection = player.selectSubtitleTrack(
      SubtitleTrack.uri('http://127.0.0.1:${server.port}/caption.sup', codec: 'sup'),
    );
    await Future.any<void>([
      requested.future,
      selection.then<void>((_) => throw StateError('PGS download completed before its test response was released.')),
    ]).timeout(const Duration(seconds: 2));
    await player.selectSubtitleTrack(SubtitleTrack.off);
    release.complete();
    await selection;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(player.pgsCue.value, isNull);
  });
}

class _LGPlayer extends native.VideoPlayerPlatform {
  bool failCreate = false;
  bool nullCreate = false;
  List<Map<String, dynamic>>? audioTracks;
  Completer<void>? initGate;
  final initializing = Completer<void>();
  PlatformException? streamError;
  final sources = <native.DataSource>[];
  final disposed = <int>[];
  final subtitleEnabled = <bool>[];
  Duration position = Duration.zero;
  final events = <int, StreamController<native.VideoEvent>>{};
  int nextId = 0;

  @override
  Future<void> init() async {
    initializing.complete();
    await initGate?.future;
  }

  @override
  Future<int?> create(native.DataSource source) async {
    if (failCreate) throw PlatformException(code: 'window-create', message: 'Native window creation failed');
    if (nullCreate) return null;
    sources.add(source);
    final id = ++nextId;
    // Closed by dispose(playerId), which owns this entry in events.
    // ignore: close_sinks
    final stream = StreamController<native.VideoEvent>();
    stream.onListen = () {
      if (streamError != null) {
        stream.addError(streamError!);
        return;
      }
      stream.add(
        native.VideoEvent(
          eventType: native.VideoEventType.initialized,
          duration: const Duration(minutes: 2),
          size: const Size(3840, 2160),
          audioTracks: audioTracks,
        ),
      );
    };
    events[id] = stream;
    return id;
  }

  @override
  Stream<native.VideoEvent> videoEventsFor(int playerId) => events[playerId]!.stream;
  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    await events[playerId]?.close();
  }

  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<Duration> getPosition(int playerId) async => position;
  @override
  Future<void> setSubtitleEnable(int playerId, bool enable) async => subtitleEnabled.add(enable);
  @override
  Future<void> setSubtitleSync(int playerId, int offset) async {}
}
