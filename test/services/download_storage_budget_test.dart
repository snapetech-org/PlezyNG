import 'dart:io';
import 'dart:typed_data';

import 'package:background_downloader/src/desktop/storage_space.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const mib = 1024 * 1024;
  late Directory directory;
  late File file;
  late IOSink sink;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('download-budget-');
    file = File('${directory.path}/video');
    await file.create();
    sink = file.openWrite();
    sink.done.ignore();
  });
  tearDown(() async {
    await sink.close();
    await directory.delete(recursive: true);
  });

  test('small network packets share a bounded sample and retain every byte', () async {
    var samples = 0;
    final observedLengths = <int>[];
    final guard = StorageSpaceGuard(
      file.path,
      1,
      capacity: (_) {
        samples++;
        observedLengths.add(file.lengthSync());
        return (available: 20 * mib, total: 100 * mib);
      },
    );
    final packet = Uint8List.fromList(List.generate(8192, (i) => i % 251));
    for (var i = 0; i < 256; i++) {
      await guard.write(sink, packet);
    }
    await sink.flush();
    expect(samples, 2);
    expect(observedLengths, [0, mib]);
    final bytes = await file.readAsBytes();
    expect(bytes.length, 2 * mib);
    for (var offset = 0; offset < bytes.length; offset += packet.length) {
      expect(Uint8List.sublistView(bytes, offset, offset + packet.length), packet);
    }
  });

  test('large chunks cannot consume the reserve after capacity drops', () async {
    var samples = 0;
    final guard = StorageSpaceGuard(
      file.path,
      1,
      capacity: (_) {
        samples++;
        return (available: samples == 1 ? 2 * mib : mib, total: 100 * mib);
      },
    );
    await expectLater(guard.write(sink, Uint8List(3 * mib)), throwsA(isA<TaskFileSystemException>()));
    await sink.flush();
    expect(file.lengthSync(), mib);
    expect(samples, 2);
  });

  test('a partial budget stops exactly at the configured free-space floor', () async {
    final guard = StorageSpaceGuard(
      file.path,
      1,
      capacity: (_) {
        return (available: mib + 37 - file.lengthSync(), total: 100 * mib);
      },
    );
    await expectLater(guard.write(sink, Uint8List(100)), throwsA(isA<TaskFileSystemException>()));
    await sink.flush();
    expect(file.lengthSync(), 37);
  });

  test('unknown-capacity volumes and disabled checks still accept bytes', () async {
    final unknown = StorageSpaceGuard(file.path, 1, capacity: (_) => throw const FileSystemException('unavailable'));
    await unknown.write(sink, [1, 2, 3]);
    final disabled = StorageSpaceGuard(file.path, 0, capacity: (_) => throw StateError('must not query'));
    await disabled.write(sink, [4, 5]);
    await sink.flush();
    expect(await file.readAsBytes(), [1, 2, 3, 4, 5]);
  });
}
