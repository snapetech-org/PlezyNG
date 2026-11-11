import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/music_car_artwork.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List png;
  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 400, 200), ui.Paint()..color = const ui.Color(0xff00ff00));
    final picture = recorder.endRecording();
    final image = await picture.toImage(400, 200);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    png = data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    image.dispose();
    picture.dispose();
  });

  test('produces a bounded aspect-preserving PNG for the native list', () async {
    final loader = MusicCarArtwork();
    final result = await loader.load(id: 'opaque', size: 96, read: () async => png, isCurrent: () => true);
    expect(result, isNotNull);
    expect(result!.length, lessThanOrEqualTo(MusicCarArtwork.maxOutputBytes));
    final buffer = await ui.ImmutableBuffer.fromUint8List(result);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    expect((descriptor.width, descriptor.height), (96, 48));
    descriptor.dispose();
    buffer.dispose();
  });

  test('invalid dimensions requests and retired callers do not read', () async {
    final loader = MusicCarArtwork();
    var reads = 0;
    Future<Uint8List?> read() async {
      reads++;
      return png;
    }

    for (final size in [0, 31, 257, 10000]) {
      expect(await loader.load(id: 'x', size: size, read: read, isCurrent: () => true), isNull);
    }
    expect(await loader.load(id: 'x', size: 128, read: read, isCurrent: () => false), isNull);
    expect(reads, 0);
  });

  test('invalid empty oversized and failed inputs leave the catalog usable', () async {
    final loader = MusicCarArtwork();
    for (final bytes in [
      Uint8List(0),
      Uint8List.fromList([1, 2, 3]),
      Uint8List(MusicCarArtwork.maxInputBytes + 1),
    ]) {
      expect(await loader.load(id: 'x', size: 128, read: () async => bytes, isCurrent: () => true), isNull);
    }
    expect(
      await loader.load(id: 'x', size: 128, read: () async => throw StateError('Unavailable'), isCurrent: () => true),
      isNull,
    );
    expect(await loader.load(id: 'x', size: 128, read: () async => png, isCurrent: () => true), isNotNull);
  });

  test('lease change while input loads discards completion and never caches it', () async {
    final loader = MusicCarArtwork();
    var current = true;
    final gate = Completer<Uint8List?>();
    final pending = loader.load(id: 'x', size: 128, read: () => gate.future, isCurrent: () => current);
    current = false;
    gate.complete(png);
    expect(await pending, isNull);
    var reads = 0;
    expect(
      await loader.load(
        id: 'x',
        size: 128,
        read: () async {
          reads++;
          return png;
        },
        isCurrent: () => true,
      ),
      isNotNull,
    );
    expect(reads, 1);
  });

  test('clearing a host retires in-flight work and its cache', () async {
    final loader = MusicCarArtwork();
    final gate = Completer<Uint8List?>();
    final old = loader.load(id: 'x', size: 128, read: () => gate.future, isCurrent: () => true);
    loader.clear();
    final fresh = await loader.load(id: 'x', size: 128, read: () async => png, isCurrent: () => true);
    expect(fresh, isNotNull);
    gate.complete(png);
    expect(await old, isNull);
  });

  test('duplicates share one read and cache hits still require a current lease', () async {
    final loader = MusicCarArtwork();
    final gate = Completer<Uint8List?>();
    var reads = 0;
    Future<Uint8List?> read() {
      reads++;
      return gate.future;
    }

    final first = loader.load(id: 'x', size: 128, read: read, isCurrent: () => true);
    final second = loader.load(id: 'x', size: 128, read: read, isCurrent: () => true);
    gate.complete(png);
    expect(await first, isNotNull);
    expect(await second, isNotNull);
    expect(reads, 1);
    expect(await loader.load(id: 'x', size: 128, read: read, isCurrent: () => true), isNotNull);
    expect(await loader.load(id: 'x', size: 128, read: read, isCurrent: () => false), isNull);
    expect(reads, 1);
  });

  test('excess simultaneous requests fail without starting another read', () async {
    final loader = MusicCarArtwork();
    final gates = List.generate(3, (_) => Completer<Uint8List?>());
    final pending = [
      for (var i = 0; i < 3; i++) loader.load(id: '$i', size: 128, read: () => gates[i].future, isCurrent: () => true),
    ];
    var fourthRead = false;
    expect(
      await loader.load(
        id: 'fourth',
        size: 128,
        read: () async {
          fourthRead = true;
          return png;
        },
        isCurrent: () => true,
      ),
      isNull,
    );
    expect(fourthRead, isFalse);
    for (final gate in gates) {
      gate.complete(null);
    }
    await Future.wait(pending);
    expect(await loader.load(id: 'fourth', size: 128, read: () async => png, isCurrent: () => true), isNotNull);
  });

  test('catalog retirement cannot reset the concurrent input budget', () async {
    final loader = MusicCarArtwork();
    final gates = List.generate(3, (_) => Completer<Uint8List?>());
    final old = [
      for (var i = 0; i < 3; i++) loader.load(id: '$i', size: 128, read: () => gates[i].future, isCurrent: () => true),
    ];
    loader.clear();
    var reads = 0;
    expect(
      await loader.load(
        id: 'fresh',
        size: 128,
        read: () async {
          reads++;
          return png;
        },
        isCurrent: () => true,
      ),
      isNull,
    );
    expect(reads, 0);
    for (final gate in gates) {
      gate.complete(png);
    }
    expect(await Future.wait(old), everyElement(isNull));
    expect(
      await loader.load(
        id: 'fresh',
        size: 128,
        read: () async {
          reads++;
          return png;
        },
        isCurrent: () => true,
      ),
      isNotNull,
    );
    expect(reads, 1);
  });

  test('bounded cache evicts the oldest presentation entry', () async {
    final loader = MusicCarArtwork();
    for (var i = 0; i < 33; i++) {
      expect(await loader.load(id: '$i', size: 32, read: () async => png, isCurrent: () => true), isNotNull);
    }
    var reads = 0;
    await loader.load(
      id: '0',
      size: 32,
      read: () async {
        reads++;
        return png;
      },
      isCurrent: () => true,
    );
    expect(reads, 1);
  });
}
