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

class _Output implements CalderaAudioOutput {
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

  test('real mesh and UDP sockets negotiate, pin source and feed bounded PCM to the output', () async {
    const native = '11111111-1111-4111-8111-111111111111';
    final address = (await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )).expand((e) => e.addresses).firstWhere(CalderaNode.privateAddress);
    final mesh = await HttpServer.bind(address, 0);
    final udp = await RawDatagramSocket.bind(address, 0);
    final output = _Output();
    var authorized = true;
    final node = CalderaNode(
      id: native,
      name: 'Native fixture',
      address: address,
      companionPort: 32500,
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
      socket = await WebSocketTransformer.upgrade(request);
      socket!.listen((frame) {
        for (final message in CalderaGroupClient.meshMessages(frame as String)) {
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
    expect(ascii.decode(output.bytes.sublist(0, 4)), 'RIFF');
    final pcm = ByteData.sublistView(Uint8List.fromList(output.bytes), 44);
    expect(pcm.getFloat32(0, Endian.little), .25);
    authorized = false;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(sink.active, isFalse);
    expect(output.closes, 1);
  }, timeout: const Timeout(Duration(seconds: 12)));
}
