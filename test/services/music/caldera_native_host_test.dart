import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/caldera_group.dart';
import 'package:plezy/services/music/caldera_native_host.dart';
import 'package:plezy/services/music/caldera_source_endpoint.dart';

import '../../test_helpers/fake_caldera_equalizer.dart';

const own = '33333333-3333-4333-8333-333333333333';
const first = '11111111-1111-4111-8111-111111111111';
const second = '22222222-2222-4222-8222-222222222222';

class _Discovery extends CalderaDiscovery {
  final entries = <CalderaNode>[];
  @override
  List<CalderaNode> get nodes => entries;
  @override
  Future<void> start() async {}
}

class _Connection {
  _Connection(this.socket) {
    socket.listen(
      (value) {
        if (value is String) messages.addAll(CalderaGroupClient.meshMessages(value));
      },
      onDone: () => closed = true,
      onError: (Object _) => closed = true,
    );
  }
  final WebSocket socket;
  final messages = <Map<String, dynamic>>[];
  bool closed = false;
  void send(String method, Object data, {String identity = first}) => socket.add(
    jsonEncode({'method': method, 'source': identity, 'data': data, 'sentAt': DateTime.now().millisecondsSinceEpoch}),
  );
  Future<void> hello() async {
    send('Hello', {'version': '1.0.0', 'capabilities': null});
    await until(() => messages.any((value) => value['method'] == 'SetState'));
  }
}

Future<void> until(bool Function() predicate) async {
  for (var attempt = 0; attempt < 200 && !predicate(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(predicate(), isTrue);
}

void main() {
  test('membership validates bounded unique UUIDs and canonicalizes only equality', () {
    expect(CalderaMembership(first, [own, first]).key, CalderaMembership(first, [first, own]).key);
    expect(
      CalderaMembership.parse({
        'source': first,
        'sinks': [own],
      }).sinks,
      [first, own],
    );
    expect(CalderaMembership.parse({'source': first, 'sinks': []}).sinks, [first]);
    for (final value in [
      null,
      {},
      {'source': first, 'sinks': 'x'},
      {
        'source': first,
        'sinks': [first, first],
      },
      {
        'source': first,
        'sinks': [first, 3],
      },
      {
        'source': 'bad',
        'sinks': ['bad'],
      },
      {'source': first, 'sinks': List.filled(10, first)},
    ]) {
      expect(() => CalderaMembership.parse(value), throwsFormatException);
    }
  });

  late CalderaNativeHost host;
  late _Discovery discovery;
  late InternetAddress address;
  final assignments = <CalderaMembership>[];
  final scopes = <bool Function()>[];
  final actions = <String>[];
  final connections = <_Connection>[];
  late FakeCalderaEqualizer equalizer;
  bool current = true;
  double volume = 50;
  Completer<void>? gate;

  setUp(() async {
    assignments.clear();
    scopes.clear();
    actions.clear();
    connections.clear();
    current = true;
    equalizer = FakeCalderaEqualizer();
    volume = 50;
    gate = null;
    address = (await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )).expand((interface) => interface.addresses).firstWhere(CalderaNode.privateAddress);
    discovery = _Discovery();
    for (final (id, ip) in [(first, address), (second, InternetAddress('192.168.244.2'))]) {
      discovery.entries.add(
        CalderaNode(
          id: id,
          name: id,
          address: ip,
          companionPort: 32500,
          expires: DateTime.now().add(const Duration(minutes: 1)),
        ),
      );
    }
    host = CalderaNativeHost(
      id: own,
      equalizer: equalizer,
      name: 'Pleazyng fixture',
      current: () => current,
      meshPort: 0,
      companionPort: 0,
      advertise: false,
      discovery: discovery,
      metadata: () => CalderaSourceMetadata(
        title: 'A title',
        artist: 'An artist',
        album: 'An album',
        state: 'playing',
        position: Duration(seconds: 3),
        duration: Duration(minutes: 3),
        volume: volume,
      ),
      control: (action, value) async {
        actions.add('$action:$value');
        if (action == 'setParameters') volume = value!.toDouble();
      },
      assign: (membership, current) async {
        assignments.add(membership);
        scopes.add(current);
        await gate?.future;
      },
    );
    await host.start();
  });
  tearDown(() async {
    gate?.complete();
    gate = null;
    for (final connection in connections) {
      unawaited(connection.socket.close());
    }
    await host.close();
  });

  Future<_Connection> connect() async {
    final connection = _Connection(await WebSocket.connect('ws://${address.address}:${host.boundMeshPort}/'));
    connections.add(connection);
    return connection;
  }

  Future<int> request(String path, {Map<String, String>? query, String? origin}) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri(scheme: 'http', host: address.address, port: host.boundCompanionPort, path: path, queryParameters: query),
      );
      request.headers.set('X-Plex-Client-Identifier', 'test-controller');
      request.headers.set('X-Plex-Target-Client-Identifier', own);
      if (origin != null) request.headers.set('Origin', origin);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  test('advertisement exposes only versioned LAN identity and bound native ports', () {
    final bytes = utf8.encode(jsonEncode(host.advertisement(address)));
    final parsed = CalderaNode.parse(bytes, address)!;
    expect(parsed.id, own);
    expect(parsed.name, 'Pleazyng fixture');
    expect(parsed.meshPort, host.boundMeshPort);
    expect(parsed.companionPort, host.boundCompanionPort);
    expect(utf8.decode(bytes), isNot(contains('token')));
  });

  test('native Hello precedes state and mesh update; endpoint retains bounded metadata', () async {
    final peer = await connect();
    await peer.hello();
    expect(peer.messages.first['source'], own);
    expect(peer.messages.first['data'], {
      'version': '1.0.0',
      'source': own,
      'capabilities': null,
      'volume': 50,
      'equalizer': {'enabled': false, 'gain': 0.0, 'bands': <Object>[]},
    });
    expect(peer.messages.any((message) => message['method'] == 'MeshUpdate'), isTrue);
    expect(await request('/resources'), 200);
    final state = await CalderaGroupClient().state(
      CalderaNode(
        id: own,
        name: 'Fixture',
        address: address,
        companionPort: host.boundCompanionPort,
        expires: DateTime.now().add(const Duration(seconds: 5)),
      ),
      current: () => true,
    );
    expect(state.player, own);
    expect(state.title, 'A title');
    expect(state.position, 3000);
  });

  for (final version in [null, '2.0.0']) {
    test('reject missing or unsupported Hello (version=$version)', () async {
      final peer = await connect();
      peer.send(
        version == null ? 'SetSinksForSource' : 'Hello',
        version == null
            ? {
                'source': first,
                'sinks': [first, own],
              }
            : {'version': version},
      );
      await until(() => peer.closed);
      expect(assignments, isEmpty);
    });
  }

  test('reserve and acknowledge membership before PCM opens; repeats do not reopen it', () async {
    gate = Completer<void>();
    final peer = await connect();
    await peer.hello();
    peer.send('SetSinksForSource', {
      'source': first,
      'sinks': [own],
    });
    await until(() => assignments.length == 1);
    await until(
      () => peer.messages.any(
        (message) => message['method'] == 'SetNodeState' && (message['data'] as Map)['source'] == first,
      ),
    );
    expect(scopes.single(), isTrue);
    peer.send('SetSinksForSource', {
      'source': first,
      'sinks': [own, first],
    });
    peer.send('SetState', {'version': '1.0.0', 'source': first});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(assignments, hasLength(1));
  });

  test('latest membership invalidates inflight scope and coalesces pending replacements', () async {
    gate = Completer<void>();
    final peer = await connect();
    await peer.hello();
    peer.send('SetSinksForSource', {
      'source': first,
      'sinks': [first, own],
    });
    await until(() => assignments.length == 1);
    peer.send('SetSinksForSource', {
      'source': own,
      'sinks': [own, second],
    });
    await until(() => !scopes.first());
    expect(assignments, hasLength(1));
    peer.send('SetSinksForSource', {
      'source': own,
      'sinks': [own, first, second],
    });
    await until(() => host.membership.sinks.length == 3);
    gate!.complete();
    gate = null;
    await until(() => assignments.length == 2);
    expect(assignments.last.sinks, [own, first, second]);
    expect(scopes.last(), isTrue);
  });

  test('removal leaves only this node and does not send remote stop', () async {
    final peer = await connect();
    await peer.hello();
    peer.send('SetSinksForSource', {
      'source': first,
      'sinks': [first, own],
    });
    await until(() => assignments.length == 1);
    peer.send('SetSinksForSource', {
      'source': first,
      'sinks': [first, second],
    });
    await until(() => assignments.length == 2);
    expect(assignments.last.key, CalderaMembership(own, [own]).key);
    expect(actions, isEmpty);
  });

  test('unknown member or identity mutation closes connection without granting membership', () async {
    var peer = await connect();
    await peer.hello();
    peer.send('SetSinksForSource', {
      'source': '44444444-4444-4444-8444-444444444444',
      'sinks': ['44444444-4444-4444-8444-444444444444', own],
    });
    await until(() => peer.closed);
    expect(assignments, isEmpty);
    peer = await connect();
    await peer.hello();
    peer.send('GetState', {}, identity: second);
    await until(() => peer.closed);
    expect(assignments, isEmpty);
  });

  test('native HTTP group commands are target-qualified and replay-protected', () async {
    final query = {'type': 'music', 'commandID': '1', 'source': own, 'sinks': first};
    expect(await request('/player/playback/setSinksForSource', query: query), 200);
    await until(() => assignments.length == 1);
    expect(assignments.single.sinks, [own, first]);
    expect(await request('/player/playback/setSinksForSource', query: query), 200);
    expect(assignments, hasLength(1));
    expect(await request('/player/playback/setSinksForSource', query: {...query, 'sinks': second}), 409);
    expect(
      await request(
        '/player/playback/setSinksForSource',
        query: {...query, 'commandID': '2', 'sinks': '$first,$first'},
      ),
      400,
    );
    expect(await request('/player/playback/pause', query: {'type': 'music', 'commandID': '2'}), 200);
    expect(actions, ['pause:null']);
  });

  test('native relayed parametric settings publish only accepted shared state', () async {
    final peer = await connect();
    await peer.hello();
    peer.send('SetSinkEqualizerEnabled', {'enabled': true});
    peer.send('SetSinkEqualizerGain', {'gain': -3.5});
    peer.send('SetSinkEqualizerBands', {
      'bands': [
        {'filterType': 0, 'frequency': 1000.0, 'gain': 2.0, 'q': .7},
      ],
    });
    await until(() => equalizer.writes.length == 3);
    expect(equalizer.calderaEqualizer.enabled, isTrue);
    expect(equalizer.calderaEqualizer.gain, -3.5);
    expect(equalizer.calderaEqualizer.bands.single.q, .7);
    await until(
      () => peer.messages.any(
        (value) => value['method'] == 'SetNodeState' && ((value['data'] as Map)['equalizer'] as Map)['gain'] == -3.5,
      ),
    );
    expect(assignments, isEmpty);
    peer.send('SetSinkEqualizerGain', {'gain': 1000});
    await until(() => peer.closed);
    expect(equalizer.writes, hasLength(3));
    expect(host.active, isTrue);
  });

  test('native relayed sink volume reaches shared controls and publishes accepted state', () async {
    final peer = await connect();
    await peer.hello();
    peer.send('SetSinkVolume', {'volume': 37});
    await until(() => actions.contains('setParameters:37'));
    await until(
      () => peer.messages.any(
        (message) => message['method'] == 'SetNodeState' && (message['data'] as Map)['volume'] == 37,
      ),
    );
    expect(host.active, isTrue);
    expect(assignments, isEmpty);
    peer.send('SetSinkVolume', {'volume': 1000});
    await until(() => peer.closed);
    expect(actions, ['setParameters:37']);
    expect(host.active, isTrue);
  });

  test('browser origins cannot use native LAN controls or mesh', () async {
    expect(await request('/resources', origin: 'https://example.invalid'), 400);
    await expectLater(
      WebSocket.connect(
        'ws://${address.address}:${host.boundMeshPort}/',
        headers: {'Origin': 'https://example.invalid'},
      ),
      throwsA(isA<WebSocketException>()),
    );
  });

  test('scope retirement closes availability and invalidates pending audio assignment', () async {
    gate = Completer<void>();
    final peer = await connect();
    await peer.hello();
    peer.send('SetSinksForSource', {
      'source': first,
      'sinks': [first, own],
    });
    await until(() => assignments.length == 1);
    current = false;
    expect(scopes.single(), isFalse);
    await until(() => !host.active && peer.closed);
    expect(host.boundCompanionPort, 0);
  });

  test('explicit playback synchronization cancels a reserved assignment', () async {
    gate = Completer<void>();
    final peer = await connect();
    await peer.hello();
    peer.send('SetSinksForSource', {
      'source': first,
      'sinks': [first, own],
    });
    await until(() => assignments.length == 1);
    host.synchronize(CalderaMembership(own, [own]));
    expect(scopes.single(), isFalse);
    expect(host.membership.source, own);
  });

  test('inbound command budget bounds a connected native flood', () async {
    final peer = await connect();
    await peer.hello();
    peer.socket.add(List.filled(32, jsonEncode({'source': first, 'method': 'GetState', 'data': {}})).join());
    for (var i = 0; i < 5; i++) {
      peer.socket.add(List.filled(32, jsonEncode({'source': first, 'method': 'GetState', 'data': {}})).join());
    }
    await until(() => peer.closed);
    expect(assignments, isEmpty);
  });
}
