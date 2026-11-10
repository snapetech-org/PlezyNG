import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/companion_remote/remote_command.dart';
import 'package:plezy/services/companion_remote/companion_remote_peer_service.dart';
import 'package:plezy/services/music/music_group_endpoint.dart';
import 'package:plezy/services/music/music_group_exchange.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/music/music_queue_controller.dart';
import 'package:plezy/services/music/music_transfer_snapshot.dart';

class _Peer extends Fake implements CompanionRemotePeerService {
  final commands = StreamController<RemoteCommand>.broadcast(sync: true);
  final disconnects = StreamController<void>.broadcast(sync: true);
  final sent = <RemoteCommand>[];
  void Function(RemoteCommand)? deliver;
  bool disposed = false;
  @override
  bool get isConnected => !disposed;
  @override
  Stream<RemoteCommand> get onCommandReceived => commands.stream;
  @override
  Stream<void> get onDeviceDisconnected => disconnects.stream;
  @override
  void sendCommand(RemoteCommand command) {
    sent.add(command);
    deliver?.call(command);
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await commands.close();
    await disconnects.close();
  }
}

void main() {
  MusicTransferSnapshot snapshot() => MusicTransferSnapshot(
    queue: MusicQueueState(
      items: [MediaItem(id: 'track', serverId: 'server', backend: MediaBackend.plex, kind: MediaKind.track)],
      order: const [0],
      cursor: 0,
      shuffled: false,
      repeatMode: MusicRepeatMode.off,
    ),
    position: const Duration(seconds: 10),
    playing: true,
  );

  test('independent authenticated endpoints share a leader and survive a sibling leaving', () async {
    final endpoints = <MusicGroupEndpoint>[];
    final followers = <MusicGroupExchange>[];
    final peers = <_Peer>[];
    var released = 0;
    for (var index = 0; index < 3; index++) {
      final peer = _Peer();
      late MusicGroupExchange follower;
      follower = MusicGroupExchange(
        allowed: () => !peer.disposed,
        capture: snapshot,
        prepare: (_, _) async => true,
        align: (_, _) async => true,
        release: () async {
          released++;
        },
        changed: () {},
        send: (data) => peer.commands.add(RemoteCommand(type: RemoteCommandType.musicGroup, data: data)),
      );
      peer.deliver = (command) {
        if (command.type == RemoteCommandType.musicGroup) follower.receive(command.data);
      };
      final endpoint = MusicGroupEndpoint(
        peer: peer,
        authorized: () => true,
        capture: snapshot,
        changed: () {},
        ended: () {},
      );
      peers.add(peer);
      endpoints.add(endpoint);
      followers.add(follower);
      expect(
        await endpoint.start((_) async {
          peer.commands.add(const RemoteCommand(type: RemoteCommandType.deviceInfo, data: {'musicGroupVersion': 1}));
        }),
        isTrue,
      );
    }
    expect(endpoints.every((endpoint) => endpoint.joined), isTrue);
    await endpoints[1].close();
    expect(peers[1].disposed, isTrue);
    expect(endpoints[0].joined && endpoints[2].joined, isTrue);
    expect(followers[0].joined && followers[2].joined, isTrue);
    expect(released, 1);
    for (final endpoint in endpoints) {
      await endpoint.close();
    }
    for (final follower in followers) {
      follower.close();
    }
  });

  test('legacy endpoints cannot receive group snapshots', () async {
    final peer = _Peer();
    final endpoint = MusicGroupEndpoint(
      peer: peer,
      authorized: () => true,
      capture: snapshot,
      changed: () {},
      ended: () {},
    );
    expect(
      await endpoint.start((_) async {
        peer.commands.add(const RemoteCommand(type: RemoteCommandType.deviceInfo, data: {}));
      }),
      isFalse,
    );
    expect(peer.sent, isEmpty);
    expect(peer.disposed, isTrue);
  });

  test('profile revocation while connecting cannot start or accept a remote group', () async {
    final peer = _Peer();
    var authorized = true;
    final gate = Completer<void>();
    final endpoint = MusicGroupEndpoint(
      peer: peer,
      authorized: () => authorized,
      capture: snapshot,
      changed: () {},
      ended: () {},
    );
    final connecting = endpoint.start((_) => gate.future);
    authorized = false;
    gate.complete();
    expect(await connecting, isFalse);
    expect(peer.sent, isEmpty);
    expect(peer.disposed, isTrue);
  });
}
