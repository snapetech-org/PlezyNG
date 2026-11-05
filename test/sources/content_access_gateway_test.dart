import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/sources/content_access.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_transport.dart';

class _GatewayAdapter extends SourceAdapter {
  _GatewayAdapter(SourceTransport transport, this._bytes)
    : super(
        const FileSource(id: 'gateway', profileId: 'profile', kind: FileSourceKind.local, name: 'Local file'),
        transport,
      );

  final List<int> _bytes;

  @override
  SourceCapabilities get capabilities => const SourceCapabilities();

  @override
  Future<SourcePage> browse({String? parent, String? cursor, String? query}) async => const SourcePage([]);

  @override
  Future<ContentLease> resolve(PublicationFile file) async => throw StateError('Direct bytes are expected.');

  @override
  Future<int?> contentSize(PublicationFile file) async => _bytes.length;

  @override
  Future<SourceByteStream?> openContent(PublicationFile file, {required int offset, required int length}) async {
    final end = (offset + length).clamp(0, _bytes.length).toInt();
    return SourceByteStream(
      stream: Stream.value(_bytes.sublist(offset, end)),
      size: _bytes.length,
      offset: offset,
      length: end - offset,
    );
  }
}

void main() {
  test('large VOD manifests retain their root and every segment capability', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      if (request.uri.path == '/vod.m3u8') {
        request.response.headers.contentType = ContentType.parse('application/vnd.apple.mpegurl');
        request.response.write('#EXTM3U\n#EXT-X-TARGETDURATION:2\n');
        for (var i = 0; i < 5000; i++) {
          request.response.write('#EXTINF:2,\nsegment-$i.ts\n');
        }
        request.response.write('#EXT-X-ENDLIST\n');
      } else {
        request.response.write(request.uri.path);
      }
      await request.response.close();
    });
    final gateway = SourceStreamGateway(valid: () => true);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await gateway.close();
      await upstream.close(force: true);
    });
    final root = await gateway.registerUri(Uri.parse('http://127.0.0.1:${upstream.port}/vod.m3u8'));
    Future<String> read(Uri uri) async {
      final response = await (await client.getUrl(uri)).close();
      expect(response.statusCode, HttpStatus.ok);
      return utf8.decoder.bind(response).join();
    }
    final manifest = await read(root);
    final urls = const LineSplitter().convert(manifest).where((line) => line.startsWith('http://')).toList();
    expect(urls, hasLength(5000));
    expect(await read(Uri.parse(urls.first)), '/segment-0.ts');
    expect(await read(Uri.parse(urls.last)), '/segment-4999.ts');
    expect(await read(root), manifest);
  });

  test('live playlist refreshes preserve the active root and retire old children', () async {
    var sequence = 0;
    var now = DateTime.utc(2026);
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      if (request.uri.path == '/live.m3u8') {
        request.response.headers.contentType = ContentType.parse('application/vnd.apple.mpegurl');
        request.response.write('#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:$sequence\n');
        for (var i = 0; i < 20; i++) {
          request.response.write('#EXTINF:2,\nsegment-${sequence + i}.ts\n');
        }
      } else {
        request.response.write(request.uri.path);
      }
      await request.response.close();
    });
    final gateway = SourceStreamGateway(valid: () => true, clock: () => now);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await gateway.close();
      await upstream.close(force: true);
    });
    final root = await gateway.registerUri(Uri.parse('http://127.0.0.1:${upstream.port}/live.m3u8'));
    Uri? oldSegment;
    for (var refresh = 0; refresh < 260; refresh++) {
      sequence = refresh * 20;
      now = now.add(const Duration(seconds: 3));
      final response = await (await client.getUrl(root)).close();
      expect(response.statusCode, HttpStatus.ok);
      final manifest = await utf8.decoder.bind(response).join();
      oldSegment ??= Uri.parse(const LineSplitter().convert(manifest).firstWhere((line) => line.startsWith('http://')));
    }
    final retired = await (await client.getUrl(oldSegment!)).close();
    expect(retired.statusCode, HttpStatus.notFound);
    await retired.drain<void>();
    final response = await (await client.getUrl(root)).close();
    expect(response.statusCode, HttpStatus.ok);
    await response.drain<void>();
  });

  test('loopback gateway serves and validates byte ranges', () async {
    final adapter = _GatewayAdapter(SourceTransport(), 'abcdef'.codeUnits);
    final gateway = SourceStreamGateway(valid: () => true);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await gateway.close();
      adapter.close();
    });
    const file = PublicationFile(id: 'video', name: 'video.mp4', mimeType: 'video/mp4', size: 6);
    final uri = await gateway.register(adapter, file);

    final rangedRequest = await client.getUrl(uri);
    rangedRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=1-3');
    final rangedResponse = await rangedRequest.close();
    expect(rangedResponse.statusCode, HttpStatus.partialContent);
    expect(rangedResponse.headers.value(HttpHeaders.contentRangeHeader), 'bytes 1-3/6');
    expect(await rangedResponse.fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk)), 'bcd'.codeUnits);

    final invalidRequest = await client.getUrl(uri);
    invalidRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=9-');
    final invalidResponse = await invalidRequest.close();
    expect(invalidResponse.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    expect(invalidResponse.headers.value(HttpHeaders.contentRangeHeader), 'bytes */6');
    await invalidResponse.drain<void>();
  });
}
