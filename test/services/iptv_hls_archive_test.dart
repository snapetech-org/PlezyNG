import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/iptv/iptv_hls_archive.dart';
import 'package:plezy/iptv/iptv_scheduled_stream_recorder.dart';
import 'package:pointycastle/export.dart';

void main() {
  test('an archive master without its payload directory has no retained media', () async {
    final directory = await Directory.systemTemp.createTemp('plezy-missing-hls-media-');
    addTearDown(() => directory.delete(recursive: true));
    final master = File('${directory.path}/recording.m3u8');
    await master.writeAsString('#EXTM3U\n#PLEZY-ARCHIVE:recording.media\nrecording.media/video.m3u8\n');
    expect(await IptvHlsArchive.retainedBytes(master), 0);
    final direct = File('${directory.path}/legacy.ts');
    await direct.writeAsBytes([1, 2, 3, 4]);
    expect(await IptvHlsArchive.retainedBytes(direct), 4);
  });

  test('scheduled completion never decrypts a truncated AES segment', () async {
    final directory = await Directory.systemTemp.createTemp('plezy-hls-aes-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final key = Uint8List.fromList(List.generate(16, (i) => i));
    final plaintext = Uint8List.fromList(List<int>.generate(188, (i) => i % 256));
    final padded = Uint8List(192)..setRange(0, plaintext.length, plaintext);
    padded.fillRange(188, 192, 4);
    final cipher = CBCBlockCipher(AESEngine())..init(true, ParametersWithIV<KeyParameter>(KeyParameter(key), Uint8List(16)));
    final ciphertext = Uint8List(padded.length);
    for (var i = 0; i < padded.length; i += 16) cipher.processBlock(padded, i, ciphertext, i);
    final started = Completer<void>(), release = Completer<void>();
    server.listen((request) async {
      if (request.uri.path == '/live.m3u8') {
        request.response.write('#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:1,\nsegment.ts\n');
      } else if (request.uri.path == '/key') {
        request.response.add(key);
      } else {
        started.complete();
        request.response.add(ciphertext.sublist(0, 17));
        await request.response.flush();
        await release.future;
        request.response.add(ciphertext.sublist(17));
      }
      await request.response.close();
    });
    final output = File('${directory.path}/programme.m3u8');
    final recorder = IptvScheduledStreamRecorder(
      uri: Uri.parse('http://127.0.0.1:${server.port}/live.m3u8'), allowHttp: true,
      outputFile: output, endsAt: DateTime.now().add(const Duration(milliseconds: 200)),
    );
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await recorder.stop();
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    final recording = recorder.record();
    await started.future;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    release.complete();
    await recording;
    final media = await IptvHlsArchive.mediaDirectory(output);
    expect(await File('${media!.path}/video-segment-0.bin').readAsBytes(), plaintext);
  });

  test('archive retains external audio, per-segment maps and discontinuities', () async {
    final directory = await Directory.systemTemp.createTemp('plezy-hls-archive-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixtures = <String, String>{
      '/master.m3u8': '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Main",DEFAULT=YES,URI="audio.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO="a"\nvideo.m3u8\n',
      '/video.m3u8': '#EXTM3U\n#EXT-X-TARGETDURATION:2\n'
          '#EXT-X-MAP:URI="init-a.mp4"\n#EXTINF:2,\nfirst.m4s\n'
          '#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI="init-b.mp4"\n#EXTINF:2,\nsecond.m4s\n#EXT-X-ENDLIST\n',
      '/audio.m3u8': '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\naudio.aac\n#EXT-X-ENDLIST\n',
      '/init-a.mp4': 'map-a', '/init-b.mp4': 'map-b',
      '/first.m4s': 'video-a', '/second.m4s': 'video-b', '/audio.aac': 'audio',
    };
    server.listen((request) async {
      final body = fixtures[request.uri.path];
      if (body == null) request.response.statusCode = 404;
      request.response.write(body ?? '');
      await request.response.close();
    });
    final output = File('${directory.path}/programme.m3u8');
    final media = Directory('${directory.path}/programme.media');
    final recorder = IptvScheduledStreamRecorder(
      uri: Uri.parse('http://127.0.0.1:${server.port}/master.m3u8'), allowHttp: true,
      outputFile: output, archiveDirectory: media,
      endsAt: DateTime.now().add(const Duration(seconds: 20)),
    );
    addTearDown(() async {
      await recorder.stop();
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    expect(await recorder.record(), '.m3u8');
    final master = await output.readAsString();
    expect(master, contains('TYPE=AUDIO'));
    expect(master, contains('programme.media/audio.m3u8'));
    expect(master, isNot(contains('http://')));
    final video = await File('${media.path}/video.m3u8').readAsString();
    expect(video, contains('video-map-0.bin'));
    expect(video, contains('video-map-1.bin'));
    expect(video.indexOf('video-map-0.bin'), lessThan(video.indexOf('video-segment-0.bin')));
    expect(video.indexOf('video-map-1.bin'), greaterThan(video.indexOf('video-segment-0.bin')));
    expect(video, contains('#EXT-X-DISCONTINUITY'));
    expect(video, contains('#EXT-X-ENDLIST'));
    expect(await File('${media.path}/audio-segment-0.bin').readAsString(), 'audio');
    expect(await File('${media.path}/video-segment-1.bin').readAsString(), 'video-b');
    expect(await IptvHlsArchive.retainedBytes(output), greaterThan(0));
  });

  test('an archive marker cannot select a parent directory or symlink', () async {
    final directory = await Directory.systemTemp.createTemp('plezy-hls-marker-');
    addTearDown(() => directory.delete(recursive: true));
    final output = File('${directory.path}/bad.m3u8');
    await output.writeAsString('#EXTM3U\n#PLEZY-ARCHIVE:..\n');
    expect(await IptvHlsArchive.mediaDirectory(output), isNull);
    await output.writeAsString('#EXTM3U\n#PLEZY-ARCHIVE:../other.media\n');
    expect(await IptvHlsArchive.mediaDirectory(output), isNull);
  });
}
