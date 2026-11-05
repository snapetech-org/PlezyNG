import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/multiview/detached_window_peer.dart';

void main() {
  Future<(DetachedWindowPeer, DetachedWindowPeer)> pair({DetachedWindowRequest? handler}) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final secret = DetachedWindowPeer.newSecret();
    final accepted = server.first.then((socket) => DetachedWindowPeer.accept(socket, secret: secret, onRequest: handler));
    final client = await DetachedWindowPeer.connect(server.port, secret: secret);
    addTearDown(client.close);
    final host = await accepted;
    addTearDown(host.close);
    await Future.wait([client.ready, host.ready]);
    return (client, host);
  }

  test('authenticated requests preserve typed PCM and native property results', () async {
    final (client, host) = await pair(handler: (method, args) async => args);
    final pcm = Uint8List.fromList([0, 255, 16, 32]);
    final response = await client.call('drainSubtitlePcm', {'pcm': pcm, 'generation': 7}) as Map;
    expect(response['pcm'], orderedEquals(pcm));
    expect(response['generation'], 7);
    final notification = client.notifications.first;
    await host.notify({'paused': true});
    expect(await notification, {'paused': true});
  });

  test('request timeout retires the connection and queued commands', () async {
    final blocked = Completer<void>();
    var calls = 0;
    final (client, host) = await pair(handler: (method, args) async {
      calls++;
      await blocked.future;
      return true;
    });
    final first = client.call('blocked', null, const Duration(milliseconds: 30));
    final second = client.call('queued');
    final expected = [expectLater(first, throwsA(isA<TimeoutException>())), expectLater(second, throwsStateError)];
    await Future.wait(expected);
    await host.closed;
    blocked.complete();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    expect(client.isClosed, isTrue);
    expect(() => client.call('late'), throwsStateError);
  });

  test('a process reusing the port cannot impersonate the parent by echoing a token', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final accepted = server.first;
    final secret = DetachedWindowPeer.newSecret();
    final client = await DetachedWindowPeer.connect(server.port, secret: secret);
    addTearDown(client.close);
    final socket = await accepted;
    addTearDown(socket.destroy);
    final received = <int>[];
    final read = socket.listen(received.addAll);
    addTearDown(read.cancel);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final payload = const StandardMessageCodec().encodeMessage({
      'type': 'challenge', 'nonce': DetachedWindowPeer.newSecret(), 'proof': '0' * 64,
    })!;
    final frame = Uint8List(payload.lengthInBytes + 4);
    ByteData.sublistView(frame).setUint32(0, payload.lengthInBytes, Endian.big);
    frame.setRange(4, frame.length, payload.buffer.asUint8List(payload.offsetInBytes, payload.lengthInBytes));
    final rejected = expectLater(client.ready, throwsStateError);
    // Header fragmentation must not bypass the authentication state machine.
    socket.add(frame.sublist(0, 3)); await socket.flush();
    socket.add(frame.sublist(3)); await socket.flush();
    await rejected;
    expect(String.fromCharCodes(received), isNot(contains(secret)));
  });
}
