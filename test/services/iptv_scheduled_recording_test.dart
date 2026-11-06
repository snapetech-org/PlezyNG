import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/iptv/iptv_scheduled_stream_recorder.dart';
import 'package:plezy/iptv/iptv_hls_archive.dart';

void main() {
  test('early direct-stream EOF preserves the captured bytes for salvage', () async {
    final now = DateTime.utc(2026, 1, 1);
    final directory = await Directory.systemTemp.createTemp('plezy-recording-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.add(List<int>.filled(188 * 8, 0x47));
      await request.response.close();
    });
    final output = File('${directory.path}/partial.ts');
    final recorder = IptvScheduledStreamRecorder(
      uri: Uri.parse('http://127.0.0.1:${server.port}/channel.ts'),
      allowHttp: true,
      outputFile: output,
      endsAt: now.add(const Duration(minutes: 1)),
      now: () => now,
    );
    addTearDown(() async {
      await recorder.stop();
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    await expectLater(recorder.record(), throwsA(isA<FileSystemException>()));
    expect(await output.length(), 188 * 8);
  });

  test('scheduled end during an HLS response retains complete segment bytes', () async {
    var now = DateTime.utc(2026, 1, 1);
    final endsAt = now.add(const Duration(seconds: 1));
    final directory = await Directory.systemTemp.createTemp('plezy-hls-recording-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final segmentStarted = Completer<void>();
    final releaseSegment = Completer<void>();
    server.listen((request) async {
      if (request.uri.path == '/live.m3u8') {
        request.response.write('#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nsegment.ts\n');
      } else {
        request.response.add(List<int>.filled(188, 0x47));
        await request.response.flush();
        segmentStarted.complete();
        await releaseSegment.future;
        request.response.add(List<int>.filled(188, 0x47));
      }
      await request.response.close();
    });
    final output = File('${directory.path}/partial.ts');
    final recorder = IptvScheduledStreamRecorder(
      uri: Uri.parse('http://127.0.0.1:${server.port}/live.m3u8'),
      allowHttp: true,
      outputFile: output,
      endsAt: endsAt,
      now: () => now,
    );
    addTearDown(() async {
      if (!releaseSegment.isCompleted) releaseSegment.complete();
      await recorder.stop();
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    final recording = recorder.record();
    await Future.any<void>([
      segmentStarted.future,
      recording.then<void>((_) => fail('Recording finished before the segment request')),
    ]);
    now = endsAt.add(const Duration(milliseconds: 1));
    releaseSegment.complete();
    await recording;
    expect(recorder.fileExtension, '.m3u8');
    expect(await IptvHlsArchive.retainedBytes(output), 188 * 2);
  });
}
