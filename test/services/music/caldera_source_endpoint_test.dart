import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/caldera_source_endpoint.dart';
import 'package:plezy/services/music/caldera_group.dart';

const sourceId = '11111111-1111-4111-8111-111111111111';
void main() {
  late InternetAddress address;
  late CalderaSourceEndpoint endpoint;
  late HttpClient http;
  late bool current;
  final actions = <String>[];
  Future<void> Function(String, int?)? handler;
  CalderaSourceMetadata metadata() => CalderaSourceMetadata(
    title: List.filled(600, 'x').join(),
    artist: 'Artist',
    album: 'Album',
    state: 'playing',
    position: const Duration(seconds: 12),
    duration: const Duration(minutes: 3),
    volume: 42,
  );
  setUp(() async {
    address = (await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )).expand((e) => e.addresses).firstWhere(CalderaNode.privateAddress);
    current = true;
    actions.clear();
    handler = null;
    http = HttpClient();
    endpoint = CalderaSourceEndpoint(
      id: sourceId,
      peers: {address.address},
      metadata: metadata,
      current: () => current,
      port: 0,
      control: (action, value) async {
        actions.add('$action:$value');
        await handler?.call(action, value);
      },
    );
    await endpoint.start();
  });
  tearDown(() async {
    http.close(force: true);
    await endpoint.close();
  });
  Future<(int, String)> get(
    String path, {
    Map<String, String> query = const {},
    String target = sourceId,
    String client = 'controller',
  }) async {
    final request = await http.getUrl(
      Uri(scheme: 'http', host: address.address, port: endpoint.boundPort, path: path, queryParameters: query),
    );
    request.headers.set('X-Plex-Target-Client-Identifier', target);
    request.headers.set('X-Plex-Client-Identifier', client);
    final response = await request.close();
    return (response.statusCode, await response.transform(utf8.decoder).join());
  }

  Future<(int, String)> command(
    String action, {
    int id = 1,
    int? value,
    String target = sourceId,
    String client = 'controller',
  }) => get(
    '/player/playback/$action',
    query: {
      'type': 'music',
      'commandID': '$id',
      if (value != null) (action == 'seekTo' ? 'offset' : 'volume'): '$value',
    },
    target: target,
    client: client,
  );
  test('selected native peers read bounded metadata through their real SSE contract', () async {
    final state = await CalderaGroupClient().state(
      CalderaNode(
        id: sourceId,
        name: 'Source',
        address: address,
        companionPort: endpoint.boundPort,
        expires: DateTime.now().add(const Duration(minutes: 1)),
      ),
      current: () => current,
    );
    expect(state.player, sourceId);
    expect(state.title.length, 512);
    expect(state.position, 12000);
    expect(state.duration, 180000);
    expect(state.volume, 42);
    final resource = await get('/resources');
    expect(resource.$1, 200);
    expect(resource.$2, contains(sourceId));
    final timeline = await get('/player/timeline/poll');
    expect(timeline.$2, contains('time="12000"'));
  });
  test('commands are bounded, target-qualified and idempotent without queue-loading authority', () async {
    expect((await command('pause')).$1, 200);
    expect((await command('pause')).$1, 200);
    expect(actions, ['pause:null']);
    expect((await command('seekTo', id: 2, value: 12000)).$1, 200);
    expect((await command('setParameters', id: 3, value: 42)).$1, 200);
    expect((await command('play', id: 3)).$1, 409);
    expect((await command('play', id: 2)).$1, 409);
    expect((await command('play', id: 4, target: 'another-owner')).$1, 409);
    expect((await command('setParameters', id: 4, value: 101)).$1, 400);
    expect((await command('seekTo', id: 4, value: -1)).$1, 400);
    expect((await command('playMedia', id: 4)).$1, 404);
    expect(actions, ['pause:null', 'seekTo:12000', 'setParameters:42']);
  });
  test('queued controls recheck scope before execution after an in-flight command', () async {
    final entered = Completer<void>(), release = Completer<void>();
    handler = (action, value) async {
      if (action == 'pause') {
        entered.complete();
        await release.future;
      }
    };
    final first = command('pause');
    await entered.future;
    final second = command('play', id: 2);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    current = false;
    release.complete();
    expect((await first).$1, 200);
    expect((await second).$1, 409);
    expect(actions, ['pause:null']);
  });
  test('a stop command can retire its own endpoint and still acknowledge', () async {
    handler = (action, value) async {
      if (action == 'stop') await endpoint.close();
    };
    final reply = await command('stop');
    expect(reply.$1, 200);
    expect(reply.$2, contains('code="200"'));
    expect(actions, ['stop:null']);
  });
  test('scope and receipt bounds cannot grow controller state indefinitely', () async {
    for (var i = 0; i < 32; i++) {
      expect((await command('pause', client: 'controller_$i')).$1, 200);
    }
    expect((await command('pause', client: 'overflow')).$1, 503);
    current = false;
    expect((await command('play', id: 2)).$1, 403);
  });
  test('unknown LAN peers receive neither state nor controls', () async {
    await endpoint.close();
    endpoint = CalderaSourceEndpoint(
      id: sourceId,
      peers: {},
      metadata: metadata,
      current: () => true,
      port: 0,
      control: (action, value) async {
        actions.add(action);
      },
    );
    await endpoint.start();
    expect((await get('/resources')).$1, 403);
    expect((await command('play')).$1, 403);
    expect(actions, isEmpty);
  });
}
