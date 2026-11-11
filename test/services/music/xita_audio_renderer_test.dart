import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/caldera_audio_output.dart';
import 'package:plezy/services/music/xita_audio_renderer.dart';
import 'package:plezy/services/music/xita_packet.dart';

class _Output implements CalderaAudioOutput {
  Object? owner;
  Uri? source;
  bool accept = true;
  Completer<void>? openGate;
  final started = Completer<void>();
  final bytes = <int>[];
  final client = HttpClient();
  StreamSubscription<List<int>>? subscription;
  int closes = 0;
  @override
  Future<bool> openCalderaAudio(Object key, Uri uri, String title, bool Function() current) async {
    source = uri;
    started.complete();
    await openGate?.future;
    if (!accept) return false;
    // Deliberately allow late acceptance to exercise defensive retirement.
    owner = key;
    if (current()) {
      subscription = (await (await client.getUrl(uri)).close()).listen(bytes.addAll);
    }
    return true;
  }

  @override
  bool ownsCalderaAudio(Object key) => identical(owner, key);
  @override
  Future<void> closeCalderaAudio(Object key) async {
    if (!ownsCalderaAudio(key)) return;
    owner = null;
    closes++;
    await subscription?.cancel();
    client.close(force: true);
  }
}

XitaDescriptor _descriptor() =>
    XitaPacket.decode(
          XitaDescriptor.encode(
            sampleRate: 8000,
            channels: 2,
            periodFrames: 80,
            frame: 0,
            timestamp: DateTime.utc(2026),
          ),
        )!
        as XitaDescriptor;

void main() {
  test('renderer streams only its opaque loopback resource and retires once', () async {
    final output = _Output();
    final clock = Stopwatch()..start();
    var current = true, closed = 0;
    final renderer = XitaAudioRenderer(
      descriptor: _descriptor(),
      output: output,
      owner: Object(),
      current: () => current,
      silent: () => false,
      title: 'Speaker',
      monotonicMicros: () => clock.elapsedMicroseconds,
      onClosed: () => closed++,
    );
    addTearDown(renderer.close);
    await renderer.start();
    expect(renderer.active, isTrue);
    expect(output.source!.host, '127.0.0.1');
    final outsider = HttpClient();
    addTearDown(() => outsider.close(force: true));
    final denied = await (await outsider.getUrl(output.source!)).close();
    expect(denied.statusCode, 404);
    await denied.drain<void>();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(output.bytes.take(44), XitaAudioRenderer.wavHeader(8000, 2));
    current = false;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await Future.wait([renderer.close(), renderer.close()]);
    expect(renderer.active, isFalse);
    expect(output.owner, isNull);
    expect(output.closes, 1);
    expect(closed, 1);
  });

  test('late accepted output cannot survive renderer retirement', () async {
    final output = _Output()..openGate = Completer<void>();
    var closed = 0;
    final renderer = XitaAudioRenderer(
      descriptor: _descriptor(),
      output: output,
      owner: Object(),
      current: () => true,
      silent: () => false,
      title: 'Speaker',
      monotonicMicros: () => 0,
      onClosed: () => closed++,
    );
    final opening = renderer.start();
    final failed = expectLater(opening, throwsStateError);
    await output.started.future;
    await renderer.close();
    output.openGate!.complete();
    await failed;
    expect(output.owner, isNull);
    expect(output.closes, 1);
    expect(closed, 1);
  });

  test('rejected output is never treated as active', () async {
    final output = _Output()..accept = false;
    final renderer = XitaAudioRenderer(
      descriptor: _descriptor(),
      output: output,
      owner: Object(),
      current: () => true,
      silent: () => false,
      title: 'Speaker',
      monotonicMicros: () => 0,
    );
    await expectLater(renderer.start(), throwsStateError);
    expect(renderer.active, isFalse);
    expect(
      renderer.add(
        XitaPacket.decode(XitaAudio.encode(frame: 0, channels: 2, samples: Float32List(160), flags: 1))! as XitaAudio,
      ),
      isFalse,
    );
    output.client.close(force: true);
  });
}
