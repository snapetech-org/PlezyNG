import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/music_pcm_capture_source.dart';
import 'package:plezy/services/music/caldera_audio_source.dart';
import 'package:plezy/services/music/caldera_group.dart';
import 'package:plezy/services/music/caldera_source_endpoint.dart';
import 'package:plezy/services/music/xita_packet.dart';

import '../../test_helpers/fake_caldera_equalizer.dart';

class _Capture implements MusicPcmCaptureSource {
  bool available = true, enabled = false;
  int frame = 0;
  final toggles = <bool>[];
  Completer<void>? enableGate, drainGate;
  @override
  Future<bool> musicPcmCaptureAvailable() async => available;
  @override
  Future<bool> setMusicPcmCaptureEnabled(bool value) async {
    if (value && enableGate != null) await enableGate!.future;
    enabled = value;
    toggles.add(value);
    return true;
  }

  @override
  Future<List<MusicPcmBlock>> drainMusicPcmCapture() async {
    if (drainGate != null) await drainGate!.future;
    if (!enabled) return [];
    final block = MusicPcmBlock(
      presentationTime: Duration(microseconds: frame * 1000000 ~/ 48000),
      sampleRate: 48000,
      channels: 2,
      samples: Float32List.fromList(List.filled(960, .25)),
      droppedFrames: 0,
      generation: 1,
    );
    frame += 480;
    return [block];
  }
}

class _Fixture {
  late HttpServer mesh;
  late RawDatagramSocket udp;
  late CalderaNode node;
  WebSocket? socket;
  final packets = <XitaPacket>[];
  final messages = <Map<String, dynamic>>[];
  final capture = _Capture();
  final equalizer = FakeCalderaEqualizer();
  final mutes = <bool>[];
  bool muted = false, current = true, feedCurrent = true;
  double replayGain = 1, volume = 50;
  int channels = 2;
  Completer<double>? gainGate;
  CalderaAudioSource? source;
  Future<void> open() async {
    final address = (await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )).expand((e) => e.addresses).firstWhere(CalderaNode.privateAddress);
    mesh = await HttpServer.bind(address, 0);
    udp = await RawDatagramSocket.bind(address, 5000);
    node = CalderaNode(
      id: '11111111-1111-4111-8111-111111111111',
      name: 'Fixture',
      address: address,
      companionPort: mesh.port,
      meshPort: mesh.port,
      expires: DateTime.now().add(const Duration(minutes: 1)),
    );
    udp.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = udp.receive()) != null) {
        final packet = XitaPacket.decode(datagram!.data);
        if (packet != null) packets.add(packet);
      }
    });
    mesh.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.write(jsonEncode(channels));
        await request.response.close();
        return;
      }
      socket = await WebSocketTransformer.upgrade(request);
      socket!.listen((frame) {
        for (final message in CalderaGroupClient.meshMessages(frame as String)) {
          messages.add(message);
          if (message['data'] == 'ping') {
            socket!.add('{"data":"ping"}');
            continue;
          }
          if (message['method'] == 'Hello') {
            socket!.add(
              jsonEncode({
                'method': 'SetState',
                'source': node.id,
                'data': {'version': '1.0.0', 'source': node.id},
              }),
            );
          } else if (message['method'] == 'SetSinksForSource') {
            socket!.add(
              jsonEncode({
                'method': 'SetNodeState',
                'source': node.id,
                'data': {'version': '1.0.0', 'source': (message['data'] as Map)['source']},
              }),
            );
          }
        }
      });
    });
  }

  CalderaAudioSource create() {
    return source = CalderaAudioSource(
      sinks: [node],
      serveCompanion: false,
      equalizer: equalizer,
      metadata: () => CalderaSourceMetadata(
        title: 'Fixture',
        artist: '',
        album: '',
        state: 'playing',
        position: Duration.zero,
        duration: Duration.zero,
        volume: volume,
      ),
      control: (action, value) async {
        if (action == 'setParameters') volume = value!.toDouble();
      },
      current: () => current,
      feeds: () => [
        CalderaPcmFeed(
          capture: capture,
          position: Duration(microseconds: capture.frame * 1000000 ~/ 48000),
          gain: .5,
          readGain: () => gainGate?.future ?? Future.value(replayGain),
          current: () => feedCurrent,
          playing: true,
          readMuted: () async => muted,
          setMuted: (value) async {
            muted = value;
            mutes.add(value);
          },
        ),
      ],
    );
  }

  Future<void> close() async {
    await source?.close();
    await socket?.close();
    udp.close();
    await mesh.close(force: true);
  }
}

Future<void> waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('Native source did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  for (final width in [2, 6, 8]) {
    test('native source negotiates $width channels without exceeding the wire MTU', () async {
      final f = _Fixture()..channels = width;
      await f.open();
      addTearDown(f.close);
      final source = f.create();
      await source.start();
      await waitFor(() => f.packets.whereType<XitaAudio>().any((p) => p.samples.any((s) => s != 0)));
      expect(f.packets.whereType<XitaDescriptor>().map((p) => p.channels), everyElement(width));
      final audio = f.packets.whereType<XitaAudio>().toList();
      expect(audio.map((p) => p.channels), everyElement(width));
      expect(audio.every((p) => p.samples.length * 4 + 20 <= 1472), isTrue);
      if (width > 2) {
        for (final packet in audio) {
          for (var frame = 0; frame < packet.frames; frame++) {
            expect(packet.samples.sublist(frame * width + 2, (frame + 1) * width), everyElement(0));
          }
        }
      }
    });
  }

  test('unsupported negotiated layout fails before capture or membership changes', () async {
    final f = _Fixture()..channels = 3;
    await f.open();
    addTearDown(f.close);
    await expectLater(f.create().start(), throwsFormatException);
    expect(f.capture.toggles, isEmpty);
    expect(f.mutes, isEmpty);
    expect(f.messages.any((message) => message['method'] == 'SetSinksForSource'), isFalse);
  });

  test('changing a verified output width retires its stream and restores local output', () async {
    final f = _Fixture()..channels = 8;
    await f.open();
    addTearDown(f.close);
    final source = f.create();
    await source.start();
    f.channels = 2;
    await waitFor(() => !source.active && !f.capture.enabled && !f.muted);
  });

  test('native source accepts independent parametric fields without replacing capture', () async {
    final f = _Fixture();
    await f.open();
    final source = f.create();
    try {
      await source.start();
      for (final (method, data) in [
        ('SetSinkEqualizerEnabled', {'enabled': true}),
        ('SetSinkEqualizerGain', {'gain': -3.5}),
        (
          'SetSinkEqualizerBands',
          {
            'bands': [
              {'filterType': 2, 'frequency': 8000, 'gain': -2, 'q': .7},
            ],
          },
        ),
      ]) {
        f.socket!.add(jsonEncode({'source': f.node.id, 'method': method, 'data': data}));
      }
      for (var i = 0; i < 100 && f.equalizer.writes.length < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(f.equalizer.calderaEqualizer.enabled, isTrue);
      expect(f.equalizer.calderaEqualizer.bands.single.filterType, 2);
      expect(source.active, isTrue);
      expect(f.capture.toggles, [true]);
    } finally {
      await f.close();
    }
  });

  test('native source accepts relayed volume without restarting capture or membership', () async {
    final f = _Fixture();
    await f.open();
    final source = f.create();
    try {
      await source.start();
      f.socket!.add(
        jsonEncode({
          'source': f.node.id,
          'method': 'SetSinkVolume',
          'data': {'volume': 37},
        }),
      );
      for (var i = 0; i < 100 && f.volume != 37; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(f.volume, 37);
      expect(source.active, isTrue);
      expect(f.capture.toggles, [true]);
      expect(f.messages.where((message) => message['method'] == 'SetSinksForSource'), hasLength(1));
      expect(
        f.messages.any((message) => message['method'] == 'SetNodeState' && (message['data'] as Map)['volume'] == 37),
        isTrue,
      );
    } finally {
      await f.close();
    }
  });

  test('native AO gain updates queued audio and a retired decoder cannot apply a late gain read', () async {
    final f = _Fixture();
    await f.open();
    addTearDown(f.close);
    final source = f.create();
    await source.start();
    await waitFor(() => f.packets.whereType<XitaAudio>().any((p) => p.samples.contains(.125)));
    f.replayGain = .5;
    f.packets.clear();
    await waitFor(() => f.packets.whereType<XitaAudio>().any((p) => p.samples.contains(.0625)));
    f.gainGate = Completer<double>();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    f.feedCurrent = false;
    f.packets.clear();
    f.gainGate!.complete(100);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(f.packets.whereType<XitaAudio>().any((p) => p.samples.contains(1)), isFalse);
    expect(source.active, isTrue);
    f.gainGate = null;
    f.feedCurrent = true;
    f.replayGain = .25;
    f.packets.clear();
    await waitFor(() => f.packets.whereType<XitaAudio>().any((p) => p.samples.contains(.03125)));
  });

  test('versioned native peer receives clocked PCM and revoked scope releases capture and mute', () async {
    final f = _Fixture();
    await f.open();
    addTearDown(f.close);
    final source = f.create();
    await source.start();
    expect(source.active, isTrue);
    expect(f.muted, isTrue);
    await waitFor(() => f.packets.whereType<XitaAudio>().any((p) => p.samples.any((s) => s != 0)));
    final descriptor = f.packets.whereType<XitaDescriptor>().first;
    expect(descriptor.sampleRate, 48000);
    expect(descriptor.channels, 2);
    final audio = f.packets.whereType<XitaAudio>().firstWhere((p) => p.samples.any((s) => s != 0));
    expect(audio.samples, everyElement(.125));
    final membership = f.messages.firstWhere((m) => m['method'] == 'SetSinksForSource')['data'];
    expect(membership, {
      'source': source.id,
      'sinks': [source.id, f.node.id],
    });
    f.current = false;
    await waitFor(() => !f.capture.enabled && !f.muted);
    final count = f.packets.length;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(f.packets.length, count);
    expect(f.capture.toggles, [true, false]);
    expect(f.mutes, [true, false]);
  });
  test('an absent native tap never changes a peer group or local mute', () async {
    final f = _Fixture();
    await f.open();
    addTearDown(f.close);
    f.capture.available = false;
    await expectLater(f.create().start(), throwsStateError);
    expect(f.messages, isEmpty);
    expect(f.mutes, isEmpty);
    expect(f.capture.toggles, isEmpty);
  });
  test('closing during capture enable retires a late lease without starting audio', () async {
    final f = _Fixture();
    await f.open();
    addTearDown(f.close);
    f.capture.enableGate = Completer<void>();
    final source = f.create();
    final started = source.start();
    final rejected = expectLater(started, throwsStateError);
    await waitFor(() => f.messages.any((m) => m['method'] == 'SetSinksForSource'));
    final closing = source.close();
    f.capture.enableGate!.complete();
    await rejected;
    await closing;
    expect(f.capture.enabled, isFalse);
    expect(f.muted, isFalse);
    expect(f.packets, isEmpty);
  });
  test('a previously muted local output remains muted after group close', () async {
    final f = _Fixture();
    await f.open();
    addTearDown(f.close);
    f.muted = true;
    final source = f.create();
    await source.start();
    await source.close();
    expect(f.muted, isTrue);
    expect(f.mutes, [true, true]);
    expect(f.capture.enabled, isFalse);
  });
  test('a peer taking source ownership retires only this transmitter', () async {
    final f = _Fixture();
    await f.open();
    addTearDown(f.close);
    final source = f.create();
    await source.start();
    f.socket!.add(
      jsonEncode({
        'method': 'SetNodeState',
        'source': f.node.id,
        'data': {'version': '1.0.0', 'source': f.node.id},
      }),
    );
    await waitFor(() => !source.active && !f.capture.enabled && !f.muted);
  });
}
