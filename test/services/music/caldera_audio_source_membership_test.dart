import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/music_pcm_capture_source.dart';
import 'package:plezy/services/music/caldera_audio_source.dart';
import 'package:plezy/services/music/caldera_group.dart';
import 'package:plezy/services/music/xita_packet.dart';

class _Capture implements MusicPcmCaptureSource {
  final clock = Stopwatch();
  final toggles = <bool>[];
  int frames = 0;
  bool enabled = false;
  @override
  Future<bool> musicPcmCaptureAvailable() async => true;
  @override
  Future<bool> setMusicPcmCaptureEnabled(bool value) async {
    enabled = value;
    toggles.add(value);
    if (value) clock.start();
    return true;
  }

  @override
  Future<List<MusicPcmBlock>> drainMusicPcmCapture() async {
    final blocks = <MusicPcmBlock>[];
    while (enabled && frames + 480 <= clock.elapsedMicroseconds * 48000 ~/ 1000000 && blocks.length < 32) {
      blocks.add(
        MusicPcmBlock(
          presentationTime: Duration(microseconds: frames * 1000000 ~/ 48000),
          sampleRate: 48000,
          channels: 2,
          samples: Float32List.fromList(List.filled(960, .25)),
          droppedFrames: 0,
          generation: 1,
        ),
      );
      frames += 480;
    }
    return blocks;
  }
}

class _Peer {
  _Peer(this.id, this.address);
  final String id;
  final InternetAddress address;
  late HttpServer server;
  late RawDatagramSocket udp;
  late CalderaNode node;
  WebSocket? socket;
  bool acknowledge = true, badVersion = false;
  String? source;
  int connections = 0;
  final received = <({XitaAudio packet, int port})>[];
  final membership = Completer<void>();
  Future<void> start() async {
    server = await HttpServer.bind(address, 0);
    udp = await RawDatagramSocket.bind(address, 5000);
    node = CalderaNode(
      id: id,
      name: 'Fixture',
      address: address,
      meshPort: server.port,
      companionPort: 32500,
      expires: DateTime.now().add(const Duration(minutes: 1)),
    );
    udp.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = udp.receive()) != null) {
        final packet = XitaPacket.decode(datagram!.data);
        if (packet is XitaAudio) received.add((packet: packet, port: datagram.port));
      }
    });
    server.listen((request) async {
      socket = await WebSocketTransformer.upgrade(request);
      connections++;
      socket!.listen((frame) {
        for (final value in CalderaGroupClient.meshMessages(frame as String)) {
          if (value['data'] == 'ping') {
            socket!.add('{"data":"ping"}');
            continue;
          }
          if (value['method'] == 'Hello') {
            socket!.add(
              jsonEncode({
                'method': 'SetState',
                'source': id,
                'data': {'version': badVersion ? '2.0.0' : '1.0.0', 'source': id},
              }),
            );
          } else if (value['method'] == 'SetSinksForSource') {
            source = (value['data'] as Map)['source'] as String;
            if (!membership.isCompleted) membership.complete();
            if (acknowledge) accept();
          }
        }
      });
    });
  }

  void accept({String? owner}) => socket?.add(
    jsonEncode({
      'method': 'SetNodeState',
      'source': id,
      'data': {'version': '1.0.0', 'source': owner ?? source},
    }),
  );
  Future<void> close() async {
    unawaited(socket?.close());
    udp.close();
    await server.close(force: true);
  }
}

Future<void> until(bool Function() predicate) async {
  for (var i = 0; i < 300 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(predicate(), isTrue);
}

Future<void> main() async {
  final addresses = (await NetworkInterface.list(type: InternetAddressType.IPv4))
      .expand((interface) => interface.addresses)
      .where(CalderaNode.privateAddress)
      .map((address) => address.address)
      .toSet()
      .map(InternetAddress.new)
      .toList();
  // Native audio fixes UDP 5000; distinct speakers require distinct LAN IPs.
  // An isolated Linux namespace with two dummy IPv4 addresses supplies these
  // deterministically without real devices or access to a media server.
  final skip = addresses.length < 2 ? 'Needs two local private IPv4 addresses (or isolated namespace fixture)' : false;
  late _Peer first, second;
  late _Capture capture;
  CalderaAudioSource? source;
  bool muted = false, current = true;
  setUp(() async {
    if (addresses.length < 2) return;
    first = _Peer('11111111-1111-4111-8111-111111111111', addresses[0]);
    second = _Peer('22222222-2222-4222-8222-222222222222', addresses[1]);
    capture = _Capture();
    source = null;
    muted = false;
    current = true;
    await first.start();
    await second.start();
  });
  tearDown(() async {
    if (addresses.length < 2) return;
    await source?.close();
    await first.close();
    await second.close();
  });
  CalderaAudioSource create(List<CalderaNode> nodes) => source = CalderaAudioSource(
    sinks: nodes,
    current: () => current,
    feeds: () => [
      CalderaPcmFeed(
        capture: capture,
        position: capture.clock.elapsed,
        gain: 1,
        playing: true,
        readMuted: () async => muted,
        setMuted: (value) async {
          muted = value;
        },
      ),
    ],
  );

  test('add/remove peers retain UDP port, decoder leases and advancing frame counter', () async {
    final source = create([first.node]);
    await source.start();
    await until(() => first.received.length >= 8);
    final port = first.received.last.port, frame = first.received.last.packet.frame;
    second.acknowledge = false;
    final change = source.replaceSinks([first.node, second.node], current: () => true);
    await second.membership.future;
    final count = first.received.length;
    await until(() => first.received.length > count + 8);
    expect(second.received, isEmpty, reason: 'Unacknowledged output receives no PCM');
    second.accept();
    await change;
    await until(() => second.received.length >= 8);
    expect(source.active, isTrue);
    expect(capture.toggles, [true]);
    expect(muted, isTrue);
    expect(second.received.map((value) => value.port).toSet(), {port});
    expect(second.received.first.packet.frame, greaterThan(frame));
    await source.replaceSinks([second.node], current: () => true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final removedCount = first.received.length, remainingCount = second.received.length;
    await until(() => second.received.length > remainingCount + 8);
    expect(first.received, hasLength(removedCount));
    expect(source.sinks.map((node) => node.id), [second.id]);
    expect(capture.toggles, [true]);
    expect(muted, isTrue);
    expect(second.received.map((value) => value.port).toSet(), {port});
  }, skip: skip);

  test('failed addition keeps the original peer audible and decoder captured', () async {
    final source = create([first.node]);
    await source.start();
    await until(() => first.received.length >= 8);
    second.badVersion = true;
    await expectLater(source.replaceSinks([first.node, second.node], current: () => true), throwsStateError);
    final before = first.received.length;
    await until(() => first.received.length > before + 8);
    expect(source.active, isTrue);
    expect(source.sinks.map((node) => node.id), [first.id]);
    expect(second.received, isEmpty);
    expect(capture.toggles, [true]);
    expect(muted, isTrue);
  }, skip: skip);

  test('cancelled pending addition cannot publish PCM or revoke the established peer', () async {
    final source = create([first.node]);
    await source.start();
    await until(() => first.received.length >= 8);
    second.acknowledge = false;
    var selected = true;
    final change = source.replaceSinks([first.node, second.node], current: () => selected);
    final rejected = expectLater(change, throwsStateError);
    await second.membership.future;
    selected = false;
    second.accept();
    await rejected;
    final before = first.received.length;
    await until(() => first.received.length > before + 8);
    expect(source.active, isTrue);
    expect(second.received, isEmpty);
    expect(muted, isTrue);
    expect(source.sinks.map((node) => node.id), [first.id]);
  }, skip: skip);

  test('a single peer departure leaves its sibling and shared source running', () async {
    final source = create([first.node, second.node]);
    await source.start();
    await until(() => first.received.length >= 8 && second.received.length >= 8);
    first.accept(owner: first.id);
    await until(() => source.sinks.length == 1);
    final before = second.received.length;
    await until(() => second.received.length > before + 8);
    expect(source.active, isTrue);
    expect(source.sinks.single.id, second.id);
    expect(capture.toggles, [true]);
    expect(muted, isTrue);
    await second.socket!.close();
    await until(() => !source.active && !capture.enabled && !muted);
    expect(capture.toggles, [true, false]);
  }, skip: skip);
}
