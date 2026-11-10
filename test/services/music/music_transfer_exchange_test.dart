import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/music/music_queue_controller.dart';
import 'package:plezy/services/music/music_transfer_exchange.dart';
import 'package:plezy/services/music/music_transfer_snapshot.dart';

void main() {
  final track = MediaItem(id: '7', backend: MediaBackend.plex, kind: MediaKind.track, serverId: 'server');
  final snapshot = MusicTransferSnapshot(
    queue: MusicQueueState(
      items: [track],
      order: const [0],
      cursor: 0,
      shuffled: false,
      repeatMode: MusicRepeatMode.off,
    ),
    position: const Duration(seconds: 12),
    playing: true,
  );

  test('the sender receives only the matching receiver acknowledgement', () async {
    final gate = Completer<bool>();
    late MusicTransferExchange sender;
    late MusicTransferExchange receiver;
    sender = MusicTransferExchange(
      allowed: () => true,
      accept: (_, _) async => false,
      send: (message) => receiver.receive(message),
    );
    receiver = MusicTransferExchange(
      allowed: () => true,
      accept: (received, current) async {
        expect(received.position, const Duration(seconds: 12));
        expect(current(), isTrue);
        return gate.future;
      },
      send: sender.receive,
    );
    addTearDown(sender.close);
    addTearDown(receiver.close);
    final result = sender.request(snapshot);
    var settled = false;
    unawaited(result.then((_) => settled = true));
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    gate.complete(true);
    expect(await result, isTrue);
  });

  test('malformed payloads are denied; a repeated request does not open twice', () async {
    var opens = 0;
    final replies = <Map<String, dynamic>>[];
    final exchange = MusicTransferExchange(
      allowed: () => true,
      accept: (_, _) async {
        opens++;
        return true;
      },
      send: replies.add,
    );
    addTearDown(exchange.close);
    final request = {
      'version': 1,
      'op': 'request',
      'request': 'abcdef0123456789abcdef0123456789',
      'snapshot': snapshot.toJson(),
    };
    exchange.receive({
      ...request,
      'snapshot': {...snapshot.toJson(), 'token': 'secret'},
    });
    await Future<void>.delayed(Duration.zero);
    expect(opens, 0);
    expect(replies.single['accepted'], isFalse);
    exchange.receive(request);
    await Future<void>.delayed(Duration.zero);
    exchange.receive(request);
    await Future<void>.delayed(Duration.zero);
    expect(opens, 1);
    expect(replies.last['accepted'], isTrue);
  });

  test('a reset invalidates a pending acknowledgement and its receiver lifetime', () async {
    final gate = Completer<bool>();
    late bool Function() current;
    late MusicTransferExchange sender;
    late MusicTransferExchange receiver;
    sender = MusicTransferExchange(
      allowed: () => true,
      accept: (_, _) async => false,
      send: (message) => receiver.receive(message),
    );
    receiver = MusicTransferExchange(
      allowed: () => true,
      accept: (_, valid) {
        current = valid;
        return gate.future;
      },
      send: sender.receive,
    );
    addTearDown(sender.close);
    addTearDown(receiver.close);
    final result = sender.request(snapshot);
    await Future<void>.delayed(Duration.zero);
    receiver.reset();
    sender.reset();
    expect(current(), isFalse);
    gate.complete(true);
    expect(await result, isFalse);
  });
}
