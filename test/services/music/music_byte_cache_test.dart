import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/music/music_byte_cache.dart';

void main() {
  late Directory root;
  late MusicByteCache cache;
  var allowed = true;
  var network = true;
  var requests = 0;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('music-cache-');
    allowed = network = true;
    requests = 0;
    cache = MusicByteCache(
      scope: 'profile-one',
      directory: () async => root,
      unmetered: () async => network,
      client: () => MockClient((request) async {
        requests++;
        return http.Response('audio-${request.url.path}', 200, headers: {'content-type': 'audio/flac'});
      }),
    );
  });
  tearDown(() async {
    cache.dispose();
    await root.delete(recursive: true);
  });
  Future<File?> prefetch(String path, {int budget = 100, String token = 'secret'}) => cache.prefetch(
    'https://music.example/$path',
    {'Authorization': 'Bearer $token'},
    budgetBytes: budget,
    wifiOnly: true,
    current: () => allowed,
  );

  test('complete bytes are reusable, credential-qualified and contain no credential manifest', () async {
    final first = await prefetch('a');
    expect(await first!.readAsString(), 'audio-/a');
    expect(await prefetch('a'), isNotNull);
    expect(requests, 1);
    expect(await prefetch('a', token: 'changed'), isNotNull);
    expect(requests, 2);
    for (final file in await root.list(recursive: true).toList()) {
      expect(file.path, isNot(contains('secret')));
      expect(file.path, isNot(contains('music.example')));
    }
    allowed = false;
    expect(await prefetch('a'), isNull);
    expect(
      await cache.lookup('https://music.example/a', {'Authorization': 'Bearer secret'}, current: () => allowed),
      isNull,
    );
  });

  test('bounded LRU eviction keeps partial and completed files within the quota', () async {
    final first = await prefetch('a', budget: 16);
    expect(await first!.exists(), isTrue);
    final second = await prefetch('b', budget: 16);
    await first.setLastModified(DateTime(2020));
    final third = await prefetch('c', budget: 16);
    expect(await first.exists(), isFalse);
    expect(await second!.exists(), isTrue);
    expect(await third!.exists(), isTrue);
    final files = (await root.list(recursive: true).toList()).whereType<File>();
    expect(await files.fold<Future<int>>(Future.value(0), (sum, file) async => await sum + await file.length()), 16);
    expect(files.where((f) => f.path.endsWith('.part')), isEmpty);
  });

  test('Wi-Fi policy and disabled cache do not start network requests', () async {
    network = false;
    expect(await prefetch('a'), isNull);
    network = true;
    expect(await prefetch('a', budget: 0), isNull);
    expect(requests, 0);
  });

  test('HTML and incomplete or oversized representations never become playable', () async {
    for (final response in [
      http.StreamedResponse(Stream.value([1, 2]), 200, headers: {'content-type': 'text/html'}),
      http.StreamedResponse(Stream.value([1, 2]), 200, contentLength: 8, headers: {'content-type': 'audio/flac'}),
      http.StreamedResponse(Stream.value(List.filled(101, 0)), 200, headers: {'content-type': 'audio/flac'}),
      http.StreamedResponse(Stream.value([1, 2]), 206, headers: {'content-type': 'audio/flac'}),
    ]) {
      final rejected = MusicByteCache(
        scope: 'reject',
        directory: () async => root,
        unmetered: () async => true,
        client: () => MockClient.streaming((_, _) async => response),
      );
      expect(
        await rejected.prefetch(
          'https://music.example/reject',
          null,
          budgetBytes: 100,
          wifiOnly: false,
          current: () => true,
        ),
        isNull,
      );
      rejected.dispose();
    }
    expect((await root.list(recursive: true).toList()).whereType<File>(), isEmpty);
  });

  test('a revoked profile cannot promote an in-flight representation', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    final delayed = MusicByteCache(
      scope: 'revoked',
      directory: () async => root,
      unmetered: () async => true,
      client: () => MockClient((_) async {
        started.complete();
        await release.future;
        return http.Response('bytes', 200, headers: {'content-type': 'audio/flac'});
      }),
    );
    final task = delayed.prefetch(
      'https://music.example/a',
      null,
      budgetBytes: 100,
      wifiOnly: false,
      current: () => allowed,
    );
    await started.future;
    allowed = false;
    release.complete();
    expect(await task, isNull);
    delayed.dispose();
    expect((await root.list(recursive: true).toList()).whereType<File>(), isEmpty);
  });

  test('clear discards a queued generation and leaves downloads outside this directory alone', () async {
    final download = File('${root.path}/owned.flac');
    await download.writeAsString('owned');
    await prefetch('a');
    await cache.clear();
    expect(await download.readAsString(), 'owned');
    expect(
      await cache.lookup('https://music.example/a', {'Authorization': 'Bearer secret'}, current: () => true),
      isNull,
    );
    expect(await prefetch('b'), isNotNull);
  });
}
