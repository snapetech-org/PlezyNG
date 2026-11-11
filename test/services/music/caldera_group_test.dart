import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/caldera_group.dart';

const _leaderId = '11111111-1111-4111-8111-111111111111';
const _sinkId = '22222222-2222-4222-8222-222222222222';

Map<String, dynamic> _beacon(String address, {int version = 1}) => {
  'available': true,
  'name': 'Native speaker',
  'interval': 1000,
  'data': {
    'proto': 'tcp',
    'companionPort': 32500,
    'port': 1998,
    'node': {
      'uuid': _leaderId,
      'version': version,
      'addresses': [
        {'address': address, 'name': 'lan'},
      ],
    },
  },
};

void main() {
  test('native mesh frames handle concatenated objects and escaped delimiters with bounds', () {
    expect(CalderaGroupClient.meshMessages('{"data":"{a}"}{"data":"ping"}'), [
      {'data': '{a}'},
      {'data': 'ping'},
    ]);
    for (final invalid in ['[]', '{"data":', '{"data":"x"}garbage', '}', '{' * 25, 'x' * 65537]) {
      expect(() => CalderaGroupClient.meshMessages(invalid), throwsFormatException);
    }
  });
  test('native discovery is bounded to a versioned beacon from its private LAN address', () {
    final address = InternetAddress('192.168.1.30');
    final now = DateTime(2026);
    final node = CalderaNode.parse(utf8.encode(jsonEncode(_beacon(address.address))), address, now: now)!;
    expect(node.id, _leaderId);
    expect(node.meshPort, 1998);
    expect(node.expires.difference(now), const Duration(seconds: 5));
    for (final invalid in [
      _beacon(address.address, version: 2),
      _beacon('192.168.1.99'),
      {..._beacon(address.address), 'available': false},
      {..._beacon(address.address), 'interval': 0},
    ]) {
      expect(CalderaNode.parse(utf8.encode(jsonEncode(invalid)), address), isNull);
    }
    expect(CalderaNode.parse(List.filled(4097, 1), address), isNull);
    expect(CalderaNode.parse([255], address), isNull);
    expect(CalderaNode.parse(utf8.encode(jsonEncode(_beacon('8.8.8.8'))), InternetAddress('8.8.8.8')), isNull);
    expect(CalderaNode.privateAddress(InternetAddress('172.32.1.1')), isFalse);
    expect(CalderaNode.privateAddress(InternetAddress.loopbackIPv4), isFalse);
  });

  group('native Companion controller on a real local HTTP socket', () {
    late HttpServer server;
    late CalderaNode leader, sink;
    late CalderaGroupClient client;
    final requests = <({String path, Map<String, String> query, Map<String, String> headers})>[];
    var meshVersion = '2.0.0', player = 'native-player', replyCode = '200';
    var redirected = false;
    var current = true;
    var stateCount = 0;

    setUp(() async {
      final addresses = [
        for (final interface in await NetworkInterface.list(type: InternetAddressType.IPv4))
          ...interface.addresses.where(CalderaNode.privateAddress),
      ];
      expect(addresses, isNotEmpty, reason: 'the socket regression needs a private local interface');
      final address = addresses.first;
      server = await HttpServer.bind(address, 0);
      leader = CalderaNode(
        id: _leaderId,
        name: 'Leader',
        address: address,
        companionPort: server.port,
        expires: DateTime.now().add(const Duration(minutes: 1)),
      );
      sink = CalderaNode(
        id: _sinkId,
        name: 'Sink',
        address: address,
        companionPort: server.port,
        expires: leader.expires,
      );
      client = CalderaGroupClient(clientIdentifier: 'test-controller');
      requests.clear();
      meshVersion = '2.0.0';
      player = 'native-player';
      replyCode = '200';
      redirected = false;
      current = true;
      stateCount = 0;
      server.listen((request) async {
        final headers = <String, String>{};
        request.headers.forEach((key, values) => headers[key] = values.join(','));
        requests.add((path: request.uri.path, query: request.uri.queryParameters, headers: headers));
        if (redirected) {
          request.response.statusCode = 302;
          request.response.headers.set('Location', 'http://127.0.0.1:1/');
        } else if (request.uri.path == '/:/eventsource/notifications') {
          stateCount++;
          request.response.headers.contentType = ContentType('text', 'event-stream');
          request.response.write(
            'event: ping\ndata: {}\n\nevent: state\ndata: ${jsonEncode({'meshVersion': meshVersion, 'playerIdentifier': player, 'type': 'track', 'title': 'A track', 'state': 'playing', 'time': 1200, 'duration': 60000, 'volume': 60})}\n\n',
          );
        } else {
          request.response.write('<Response code="$replyCode" status="accepted"/>');
        }
        await request.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    test('manual access learns the mesh identity and verifies native state', () async {
      final mesh = await HttpServer.bind(leader.address, 0);
      addTearDown(() => mesh.close(force: true));
      mesh.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        try {
          final hello = CalderaGroupClient.meshMessages(await socket.first as String).single;
          expect(hello['method'], 'Hello');
          expect(hello['data'], {'capabilities': null, 'version': '1.0.0'});
          socket.add(
            jsonEncode({
              'method': 'SetState',
              'source': _leaderId,
              'data': {'version': '1.0.0'},
            }),
          );
        } finally {
          await socket.close();
        }
      });
      final node = await client.inspect(leader.endpoint, meshPort: mesh.port, current: () => current);
      expect(node.id, leader.id);
      expect(node.endpoint, leader.endpoint);
      expect(node.meshPort, mesh.port);
      await expectLater(client.inspect('8.8.8.8:32500', current: () => current), throwsArgumentError);
      await expectLater(client.inspect('user:secret@192.168.1.1:32500', current: () => current), throwsArgumentError);
    });

    test('reads state and sends an explicit group, transport, volume and ungroup', () async {
      final state = await client.state(leader, current: () => current);
      expect(state.title, 'A track');
      await client.group(leader, state, [sink], current: () => current);
      await client.transport(leader, state, 'pause', current: () => current);
      await client.volume(sink, state, 42, current: () => current);
      await client.group(leader, state, [], current: () => current);
      final commands = requests.where((request) => request.path.startsWith('/player/playback/')).toList();
      expect(commands.map((request) => request.query['commandID']), ['1', '2', '3', '4']);
      expect(commands.first.query, containsPair('source', _leaderId));
      expect(commands.first.query, containsPair('sinks', _sinkId));
      expect(commands.last.query, containsPair('sinks', ''));
      expect(commands[2].query, containsPair('volume', '42'));
      for (final command in commands) {
        expect(command.headers['x-plex-target-client-identifier'], 'native-player');
        expect(command.headers['x-plex-client-identifier'], 'test-controller');
        expect(command.headers['x-plex-token'], isNull);
      }
      expect(stateCount, greaterThanOrEqualTo(5));
    });
    test('refuses protocol changes, replacement identities, redirects and lost profile scope', () async {
      final state = await client.state(leader, current: () => current);
      meshVersion = '3.0.0';
      await expectLater(client.group(leader, state, [sink], current: () => current), throwsFormatException);
      meshVersion = '2.0.0';
      player = 'replacement';
      await expectLater(client.transport(leader, state, 'play', current: () => current), throwsStateError);
      expect(requests.where((request) => request.path.startsWith('/player/playback/')), isEmpty);
      player = 'native-player';
      redirected = true;
      await expectLater(client.state(leader, current: () => current), throwsStateError);
      redirected = false;
      replyCode = '403';
      await expectLater(client.transport(leader, state, 'play', current: () => current), throwsStateError);
      current = false;
      final count = requests.length;
      await expectLater(client.transport(leader, state, 'stop', current: () => current), throwsStateError);
      expect(requests.length, count);
    });
  });
}
