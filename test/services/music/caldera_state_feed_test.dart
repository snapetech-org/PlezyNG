import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/caldera_group.dart';
import 'package:plezy/services/music/caldera_state_feed.dart';

const peer = '11111111-1111-4111-8111-111111111111';
Map<String, Object> state({String id = 'caldera-reference-player', String status = 'playing', int time = 1000}) => {
  'meshVersion': '2.0.0',
  'playerIdentifier': id,
  'type': 'track',
  'title': 'Source title',
  'artist': 'Artist',
  'album': 'Album',
  'state': status,
  'volume': 70,
  'time': time,
  'duration': 180000,
};
void main() {
  test('long state subscription resets its byte budget and preserves paused metadata', () async {
    final address = (await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )).expand((e) => e.addresses).firstWhere(CalderaNode.privateAddress);
    final server = await HttpServer.bind(address, 0);
    HttpResponse? response;
    final snapshots = <CalderaNowPlaying>[];
    var failures = 0;
    final feed = CalderaStateFeed(
      node: CalderaNode(
        id: peer,
        name: 'Fixture',
        address: address,
        companionPort: server.port,
        expires: DateTime.now(),
      ),
      current: () => true,
      changed: snapshots.add,
      failed: () => failures++,
    );
    addTearDown(() async {
      feed.close();
      try {
        await response?.close();
      } on Object {
        // The subscription has already closed this client connection.
      }
      await server.close(force: true);
    });
    server.listen((request) {
      response = request.response;
      response!.headers.contentType = ContentType('text', 'event-stream');
      response!.bufferOutput = false;
      response!.write('event: state\ndata: ${jsonEncode(state())}\n\n');
      unawaited(response!.flush());
    });
    await feed.start();
    expect(snapshots.single.artist, 'Artist');
    for (var n = 0; n < 400; n++) {
      response!.write('event: state\ndata: ${jsonEncode(state(status: 'paused', time: n))}\n\n');
    }
    await response!.flush();
    await pumpEventQueue(times: 100);
    expect(snapshots.length, 401);
    expect(snapshots.last.snapshot.state, 'paused');
    expect(snapshots.last.snapshot.position, 399);
    expect(failures, 0);
  });
  for (final kind in ['identity', 'oversize', 'scope', 'ended']) {
    test('retire native state on $kind without stale presentation', () async {
      final address = (await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )).expand((e) => e.addresses).firstWhere(CalderaNode.privateAddress);
      final server = await HttpServer.bind(address, 0);
      HttpResponse? response;
      var current = true, failed = 0;
      final snapshots = <CalderaNowPlaying>[];
      final feed = CalderaStateFeed(
        node: CalderaNode(
          id: peer,
          name: 'Fixture',
          address: address,
          companionPort: server.port,
          expires: DateTime.now(),
        ),
        current: () => current,
        changed: snapshots.add,
        failed: () => failed++,
      );
      addTearDown(() async {
        feed.close();
        await server.close(force: true);
      });
      server.listen((request) {
        response = request.response;
        response!.headers.contentType = ContentType('text', 'event-stream');
        response!.bufferOutput = false;
        response!.write('event: state\ndata: ${jsonEncode(state())}\n\n');
        unawaited(response!.flush());
      });
      await feed.start();
      if (kind == 'scope') current = false;
      if (kind == 'ended') {
        await response!.close();
      } else {
        response!.write(
          kind == 'oversize'
              ? 'data: ${'x' * 65537}'
              : 'event: state\ndata: ${jsonEncode(state(id: kind == 'identity' ? 'other-source' : peer))}\n\n',
        );
        await response!.flush();
      }
      await pumpEventQueue(times: 100);
      expect(snapshots.length, 1);
      expect(failed, 1);
    });
  }
  test('metadata parser rejects invalid states, bounds and optional fields', () {
    for (final change in <Map<String, Object>>[
      {'volume': 101},
      {'time': -1},
      {'duration': 86400001},
      {'state': 'unknown'},
      {'artist': 123},
      {'album': 'x' * 513},
      {'meshVersion': '1.0.0'},
    ]) {
      expect(() => CalderaNowPlaying.parse({...state(), ...change}), throwsFormatException);
    }
  });
}
