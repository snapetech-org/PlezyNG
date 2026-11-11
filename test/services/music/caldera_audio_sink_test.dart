import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/caldera_audio_sink.dart';
import 'package:plezy/services/music/caldera_group.dart';
import 'package:plezy/services/music/xita_packet.dart';

XitaDescriptor descriptor({int rate = 8000}) =>
    XitaPacket.decode(
          XitaDescriptor.encode(
            sampleRate: rate,
            channels: 2,
            periodFrames: 80,
            frame: 0,
            timestamp: DateTime.utc(2026),
          ),
        )!
        as XitaDescriptor;
XitaAudio audio(int frame, {int count = 80, double value = .5, int flags = 1}) =>
    XitaPacket.decode(
          XitaAudio.encode(
            frame: frame,
            channels: 2,
            samples: Float32List.fromList(List.filled(count * 2, value)),
            flags: flags,
          ),
        )!
        as XitaAudio;

class _Output implements CalderaAudioOutput, CalderaAudioMetadataOutput {
  final metadata = <CalderaNowPlaying>[];
  @override
  void updateCalderaMetadata(Object key, CalderaNowPlaying value) {
    if (ownsCalderaAudio(key)) metadata.add(value);
  }

  Object? owner;
  final client = HttpClient();
  StreamSubscription<List<int>>? subscription;
  final bytes = <int>[];
  int closes = 0;
  @override
  Future<bool> openCalderaAudio(Object key, Uri uri, String title, bool Function() current) async {
    if (!current()) return false;
    owner = key;
    final response = await (await client.getUrl(uri)).close();
    subscription = response.listen(bytes.addAll);
    return current();
  }

  @override
  bool ownsCalderaAudio(Object key) => identical(key, owner);
  @override
  Future<void> closeCalderaAudio(Object key) async {
    if (!ownsCalderaAudio(key)) return;
    owner = null;
    closes++;
    await subscription?.cancel();
    client.close(force: true);
  }
}

class _ClockOutput extends _Output implements CalderaAudioClockOutput {
  _ClockOutput({this.warmupMicros = 50000});
  final int warmupMicros;
  final clock = Stopwatch();
  @override
  Future<bool> openCalderaAudio(Object key, Uri uri, String title, bool Function() current) {
    clock.start();
    return super.openCalderaAudio(key, uri, title, current);
  }

  @override
  bool hasCalderaAudioClock(Object key) => ownsCalderaAudio(key);
  @override
  Future<Duration?> readCalderaAudioClock(Object key) async {
    if (!ownsCalderaAudio(key) || clock.elapsedMicroseconds < warmupMicros) return null;
    final available = (bytes.length - 44).clamp(0, 1 << 40) ~/ 8;
    final pts = ((clock.elapsedMicroseconds - warmupMicros) * .999).round();
    return Duration(microseconds: pts.clamp(0, available * 1000000 ~/ 8000));
  }
}

void main() {
  test('jitter window reorders PCM, conceals exact gaps and drops replays/overlap', () {
    final buffer = XitaJitterBuffer(descriptor());
    expect(buffer.add(audio(0), 0), isTrue);
    expect(buffer.add(audio(160, value: .25, flags: 0), 20000), isTrue);
    expect(buffer.add(audio(80, value: -.5, flags: 0), 25000), isTrue);
    expect(buffer.add(audio(80), 25001), isFalse);
    expect(buffer.add(audio(100), 25002), isFalse);
    expect(buffer.add(audio(80000), 25003), isFalse);
    expect(buffer.render(149999), isEmpty);
    final rendered = ByteData.sublistView(buffer.render(180000));
    expect(rendered.lengthInBytes, 240 * 8);
    expect(rendered.getFloat32(0, Endian.little), .5);
    expect(rendered.getFloat32(80 * 8, Endian.little), -.5);
    expect(rendered.getFloat32(160 * 8, Endian.little), .25);
    expect(buffer.missingFrames, 0);
    final silence = buffer.render(190000);
    expect(silence, everyElement(0));
    expect(buffer.missingFrames, 80);
    expect(buffer.add(audio(80), 30000), isFalse);
  });
  test('scheduled output includes renderer delay and interpolates across packet boundaries', () {
    XitaJitterBuffer make() {
      final buffer = XitaJitterBuffer(descriptor());
      buffer.add(audio(0, value: 0), 0);
      buffer.add(audio(80, value: 1, flags: 0), 10000);
      return buffer;
    }

    final early = ByteData.sublistView(make().renderScheduled(80, presentationMicros: 140000, microsPerFrame: 125));
    expect(early.buffer.asUint8List(), everyElement(0));
    // Bytes supplied at local 100 ms, audible 50 ms later, belong to frame 0.
    final delayed = ByteData.sublistView(make().renderScheduled(2, presentationMicros: 150000, microsPerFrame: 125));
    expect(delayed.getFloat32(0, Endian.little), 0);
    // Half a source sample across adjacent UDP packets must blend both.
    final boundary = ByteData.sublistView(
      make().renderScheduled(2, presentationMicros: 150000 + 79.5 * 125, microsPerFrame: 125),
    );
    expect(boundary.getFloat32(0, Endian.little), closeTo(.5, 1e-6));
    expect(boundary.getFloat32(8, Endian.little), 1);
    expect(() => make().renderScheduled(4097, presentationMicros: 0, microsPerFrame: 125), throwsArgumentError);
  });

  test('jitter allocations stay bounded under a peer flood', () {
    final buffer = XitaJitterBuffer(descriptor());
    for (var frame = 0; frame < 80000; frame += 80) {
      buffer.add(audio(frame), frame * 125);
    }
    expect(buffer.droppedPackets, greaterThan(900));
    expect(buffer.render(10000000).length, lessThanOrEqualTo(4096 * 8));
  });
  test('WAV bridge declares little-endian IEEE float and the negotiated channels/rate', () {
    final header = CalderaAudioSink.wavHeader(48000, 6);
    final data = ByteData.sublistView(header);
    expect(ascii.decode(header.sublist(0, 4)), 'RIFF');
    expect(data.getUint16(20, Endian.little), 3);
    expect(data.getUint16(22, Endian.little), 6);
    expect(data.getUint32(24, Endian.little), 48000);
    expect(data.getUint32(28, Endian.little), 48000 * 24);
    expect(data.getUint16(34, Endian.little), 32);
  });

  for (final warmup in [null, 50000, 600000]) {
    final clocked = warmup != null;
    test(
      'real mesh and UDP sockets negotiate, pin source and feed bounded PCM to the output (renderer warmup=$warmup)',
      () async {
        const native = '11111111-1111-4111-8111-111111111111';
        final address = (await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        )).expand((e) => e.addresses).firstWhere(CalderaNode.privateAddress);
        final mesh = await HttpServer.bind(address, 0);
        final udp = await RawDatagramSocket.bind(address, 0);
        final output = clocked ? _ClockOutput(warmupMicros: warmup) : _Output();
        final states = <HttpResponse>{};
        final controls = <String>[];
        var remoteState = 'playing';
        Map<String, Object> snapshot() => {
          'meshVersion': '2.0.0',
          'type': 'track',
          'playerIdentifier': 'caldera-companion-identity',
          'title': 'Remote track',
          'grandparentTitle': 'Remote artist',
          'parentTitle': 'Remote album',
          'state': remoteState,
          'volume': 50,
          'time': 1000,
          'duration': 180000,
        };
        void publish() {
          for (final response in states.toList()) {
            response.write('event: state\ndata: ${jsonEncode(snapshot())}\n\n');
            unawaited(
              response.flush().catchError((Object _) {
                states.remove(response);
              }),
            );
          }
        }

        var authorized = true;
        final node = CalderaNode(
          id: native,
          name: 'Native fixture',
          address: address,
          companionPort: mesh.port,
          meshPort: mesh.port,
          expires: DateTime.now().add(const Duration(minutes: 1)),
        );
        final sink = CalderaAudioSink(leader: node, output: output, current: () => authorized);
        Timer? producer;
        WebSocket? socket;
        final group = Completer<Map<String, dynamic>>();
        addTearDown(() async {
          producer?.cancel();
          await sink.close();
          await socket?.close();
          udp.close();
          await mesh.close(force: true);
        });
        mesh.listen((request) async {
          if (request.uri.path == '/:/eventsource/notifications') {
            request.response.headers.contentType = ContentType('text', 'event-stream');
            request.response.bufferOutput = false;
            states.add(request.response);
            unawaited(
              request.response.done.then<void>(
                (_) {
                  states.remove(request.response);
                },
                onError: (Object _) {
                  states.remove(request.response);
                },
              ),
            );
            publish();
            return;
          }
          if (request.uri.path.startsWith('/player/playback/')) {
            expect(request.headers.value('X-Plex-Target-Client-Identifier'), 'caldera-companion-identity');
            final action = request.uri.path.split('/').last;
            controls.add(action);
            if (action == 'pause') remoteState = 'paused';
            if (action == 'play') remoteState = 'playing';
            if (action == 'seekTo') expect(request.uri.queryParameters['offset'], '180000');
            publish();
            await request.response.close();
            return;
          }
          socket = await WebSocketTransformer.upgrade(request);
          socket!.listen((frame) {
            for (final message in CalderaGroupClient.meshMessages(frame as String)) {
              if (message['data'] == 'ping') {
                socket!.add('{"data":"ping"}');
                continue;
              }
              if (message['method'] == 'Hello') {
                socket!.add(
                  jsonEncode({
                    'method': 'SetState',
                    'source': native,
                    'data': {'version': '1.0.0', 'source': native, 'volume': 50},
                  }),
                );
              } else if (message['method'] == 'SetSinksForSource') {
                group.complete(message);
                udp.send(
                  XitaDescriptor.encode(
                    sampleRate: 8000,
                    channels: 2,
                    periodFrames: 80,
                    frame: 0,
                    timestamp: DateTime.now(),
                  ),
                  InternetAddress.loopbackIPv4,
                  5000,
                );
                var frame = 0;
                producer = Timer.periodic(const Duration(milliseconds: 10), (_) {
                  udp.send(
                    XitaAudio.encode(
                      frame: frame,
                      channels: 2,
                      samples: Float32List.fromList(List.filled(160, .25)),
                      flags: 1,
                    ),
                    InternetAddress.loopbackIPv4,
                    5000,
                  );
                  frame += 80;
                });
              }
            }
          });
        });
        await sink.start().timeout(const Duration(seconds: 5));
        expect(sink.active, isTrue);
        final request = await group.future;
        expect(request['data'], {
          'source': native,
          'sinks': [native, sink.id],
        });
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(output.bytes.length, greaterThan(44));
        if (warmup == 600000) {
          expect(
            output.bytes.length,
            lessThanOrEqualTo(44 + 800 * 8),
            reason: 'Unavailable audible clock must not accumulate more than 100 ms of priming silence',
          );
          expect(output.bytes.sublist(44), everyElement(0));
          await Future<void>.delayed(const Duration(milliseconds: 650));
          expect(sink.active, isTrue);
        }
        expect(ascii.decode(output.bytes.sublist(0, 4)), 'RIFF');
        final pcm = ByteData.sublistView(Uint8List.fromList(output.bytes), 44);
        expect([for (var i = 0; i + 4 <= pcm.lengthInBytes; i += 4) pcm.getFloat32(i, Endian.little)], contains(.25));
        expect(output.metadata.last.snapshot.title, 'Remote track');
        expect(output.metadata.last.artist, 'Remote artist');
        await sink.control('pause');
        producer?.cancel();
        udp.send(
          XitaDescriptor.encode(
            sampleRate: 8000,
            channels: 2,
            periodFrames: 80,
            frame: 0,
            timestamp: DateTime.now(),
            flags: 2,
          ),
          InternetAddress.loopbackIPv4,
          5000,
        );
        final beforePause = output.bytes.length;
        await Future<void>.delayed(const Duration(milliseconds: 5600));
        expect(sink.active, isTrue, reason: 'Paused sources retain membership beyond audio-idle timeout');
        expect(output.bytes.length, greaterThan(beforePause + 8000), reason: 'Keep live decoder supplied with silence');
        expect(output.metadata.last.snapshot.state, 'paused');
        await sink.control('seek', position: const Duration(days: 1));
        await sink.control('skipNext');
        await sink.control('skipPrevious');
        await sink.control('play');
        var resumedFrame = 0;
        producer = Timer.periodic(const Duration(milliseconds: 10), (_) {
          udp.send(
            XitaAudio.encode(
              frame: resumedFrame,
              channels: 2,
              samples: Float32List.fromList(List.filled(160, -.5)),
              flags: 1,
            ),
            InternetAddress.loopbackIPv4,
            5000,
          );
          resumedFrame += 80;
        });
        final beforeResume = output.bytes.length;
        await Future<void>.delayed(const Duration(milliseconds: 350));
        final resumed = ByteData.sublistView(Uint8List.fromList(output.bytes.sublist(beforeResume)));
        expect([
          for (var i = 0; i + 4 <= resumed.lengthInBytes; i += 4) resumed.getFloat32(i, Endian.little),
        ], contains(-.5));
        expect(controls, ['pause', 'seekTo', 'skipNext', 'skipPrevious', 'play']);
        authorized = false;
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(sink.active, isFalse);
        expect(output.closes, 1);
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  }
}
