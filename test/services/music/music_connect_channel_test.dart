import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/music_connect_channel.dart';

void main() {
  test('an authenticated long Unicode request and response survive framing', () async {
    late MusicConnectChannel sender;
    late MusicConnectChannel receiver;
    final queue = List.filled(4096, 'musique 音楽 🎵');
    sender = MusicConnectChannel(send: (m) => receiver.receive(m), handle: (_) async => null, allowed: () => true);
    receiver = MusicConnectChannel(
      send: sender.receive,
      handle: (m) async => {'ok': true, 'tracks': m['tracks']},
      allowed: () => true,
    );
    addTearDown(sender.close);
    addTearDown(receiver.close);
    expect(await sender.request({'tracks': queue}), {'ok': true, 'tracks': queue});
  });

  test('retiring a connection invalidates its pending reply', () async {
    final answer = Completer<MusicConnectMessage?>();
    late MusicConnectChannel sender;
    late MusicConnectChannel receiver;
    sender = MusicConnectChannel(send: (m) => receiver.receive(m), handle: (_) async => null, allowed: () => true);
    receiver = MusicConnectChannel(send: sender.receive, handle: (_) => answer.future, allowed: () => true);
    addTearDown(receiver.close);
    final pending = sender.request({'op': 'commit'});
    sender.close();
    expect(await pending, isNull);
    answer.complete({'ok': true});
    await Future<void>.delayed(Duration.zero);
  });

  test('missing and reordered frames do not execute a request', () async {
    final frames = <MusicConnectMessage>[];
    var calls = 0;
    final sender = MusicConnectChannel(send: frames.add, handle: (_) async => null, allowed: () => true);
    final receiver = MusicConnectChannel(
      send: (_) {},
      handle: (_) async {
        calls++;
        return {'ok': true};
      },
      allowed: () => true,
    );
    final pending = sender.request({'queue': 'a' * 50000});
    receiver.receive(frames[1]);
    receiver.receive(frames[0]);
    receiver.receive(frames[2]);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 0);
    sender.close();
    receiver.close();
    expect(await pending, isNull);
  });
}
