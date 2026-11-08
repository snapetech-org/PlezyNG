import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/platform/player_webos.dart';
import 'package:video_player_drm/video_player_platform_interface.dart' as native;
import 'package:plezy/widgets/video_controls/widgets/performance_overlay/performance_stats_service.dart';
import 'package:plezy/widgets/video_controls/widgets/video_controls_header.dart';

import '../fixtures/pgs_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final inheritedHttpOverrides = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = inheritedHttpOverrides);

  test('LG unknown audio uses explicit original-source metadata without claiming receiver output', () async {
    final backend = _LGPlayer()
      ..audioTracks = [
        {'trackId': 0, 'codec': 'unknown', 'channels': 0, 'sampleRate': 0},
      ];
    native.VideoPlayerPlatform.instance = backend;
    final player = PlayerWebOS();
    addTearDown(player.dispose);
    await player.setProperty(
      'webos-source-audio-metadata',
      jsonEncode([
        {'codec': 'dca', 'codecProfile': 'ma', 'channels': 6, 'sampleRate': 48000, 'bitRate': 4000000},
      ]),
    );
    await player.open(Media('/original.mkv'));
    backend.events[1]!.add(
      native.VideoEvent(
        eventType: native.VideoEventType.trackSelected,
        trackSelectedType: 'audio',
        trackSelectedIndex: 0,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(activeAudioFormatLabel(player.state.track.audio), 'DTS-HD MA · 5.1');
    expect(await player.getProperty('audio-codec-name'), 'DTS-HD MA');
    expect(await player.getProperty('webos-audio-metadata-origin'), 'server-source');
    expect(await player.getProperty('audio-out-params/channel-count'), isNull);
    // Opening another source without hints cannot inherit that format.
    await player.open(Media('/another.mkv'));
    backend.events[2]!.add(
      native.VideoEvent(
        eventType: native.VideoEventType.trackSelected,
        trackSelectedType: 'audio',
        trackSelectedIndex: 0,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(player.state.track.audio?.codec, isNull);
    expect(await player.getProperty('webos-audio-metadata-origin'), 'unreported');
  });

  test('native format wins and a partial catalog never borrows another stream format', () async {
    final backend = _LGPlayer()
      ..audioTracks = [
        {'trackId': 0, 'codec': 'aac', 'channels': 2},
        {'trackId': 1, 'codec': 'unknown'},
      ];
    native.VideoPlayerPlatform.instance = backend;
    final player = PlayerWebOS();
    addTearDown(player.dispose);
    await player.setProperty(
      'webos-source-audio-metadata',
      jsonEncode([
        {'codec': 'dca', 'channels': 6},
      ]),
    );
    await player.open(Media('/original.mkv'));
    expect(player.state.tracks.audio.first.codec, 'aac');
    expect(player.state.tracks.audio.first.channels, 2);
    expect(player.state.tracks.audio.last.codec, isNull);
  });

  test('native codec metadata reaches tracks, the audio label and performance stats', () async {
    final backend = _LGPlayer()
      ..audioTracks = [
        {'trackId': 0, 'codec': 'dca-ma', 'channels': 6, 'sampleRate': 48000, 'bitRate': 4000000},
        {'trackId': 1, 'codec': 'aac', 'channels': 2, 'sampleRate': 48000},
      ]
      ..videoInfo = {'codec': 'hevc', 'frameRate': 23.976, 'bitRate': 45000000};
    native.VideoPlayerPlatform.instance = backend;
    final player = PlayerWebOS();
    addTearDown(player.dispose);
    await player.open(Media('/movie.mkv'));
    backend.events[1]!.add(
      native.VideoEvent(
        eventType: native.VideoEventType.trackSelected,
        trackSelectedType: 'audio',
        trackSelectedIndex: 0,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(player.state.track.audio?.channels, 6);
    expect(activeAudioFormatLabel(player.state.track.audio), 'DTS-HD MA · 5.1');
    final service = PerformanceStatsService(player);
    addTearDown(service.dispose);
    final result = service.statsStream.first;
    service.startPolling();
    final stats = await result;
    expect(stats.videoCodec, 'HEVC');
    expect(stats.audioCodec, 'DTS-HD MA');
    expect(stats.audioChannels, '6');
    expect(stats.audioSamplerate, 48000);
    expect(stats.audioPassthrough, isFalse);
    expect(await player.getProperty('audio-out-params/channel-count'), isNull);
    backend.events[1]!.add(
      native.VideoEvent(
        eventType: native.VideoEventType.trackSelected,
        trackSelectedType: 'audio',
        trackSelectedIndex: 1,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(activeAudioFormatLabel(player.state.track.audio), 'AAC · Stereo');
  });

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

  test('a same-origin redirect cannot stall subtitles with an unfinished response body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requested = <String>[];
    server.listen((request) async {
      requested.add(request.uri.path);
      if (request.uri.path == '/redirect') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/caption.sup');
        request.response.write('unused redirect body');
        await request.response.flush();
        // Intentionally leave it unfinished. The client must cancel it.
      } else {
        request.response.add(syntheticPgsFixture());
        await request.response.close();
      }
    });
    native.VideoPlayerPlatform.instance = _LGPlayer();
    final player = PlayerWebOS();
    addTearDown(() async {
      await player.dispose();
      await server.close(force: true);
    });
    await player.open(Media('/movie.mkv'));
    await player
        .selectSubtitleTrack(SubtitleTrack.uri('http://127.0.0.1:${server.port}/redirect', codec: 'pgs'))
        .timeout(const Duration(seconds: 3));
    expect(requested, ['/redirect', '/caption.sup']);
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
  Map<String, dynamic>? videoInfo;
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
          videoInfo: videoInfo,
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
