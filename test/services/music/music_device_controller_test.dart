import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/music/music_connect_channel.dart';
import 'package:plezy/services/music/music_device_controller.dart';
import 'package:plezy/services/music/music_device_endpoint.dart';
import 'package:plezy/services/music/music_device_link.dart';
import 'package:plezy/services/music/music_device_session.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/music/music_queue_controller.dart';
import 'package:plezy/services/music/music_transfer_snapshot.dart';

import '../../test_helpers/stub_music_playback_service.dart';

MusicTransferSnapshot _queue({int index = 0, int seconds = 31, bool playing = true}) {
  final items = [
    MediaItem(id: 'a', backend: MediaBackend.plex, kind: MediaKind.track, serverId: 'plex', title: 'A'),
    MediaItem(id: 'a', backend: MediaBackend.plex, kind: MediaKind.track, serverId: 'plex', title: 'A again'),
    MediaItem(id: 'b', backend: MediaBackend.plex, kind: MediaKind.track, serverId: 'plex', title: 'B'),
  ];
  return MusicTransferSnapshot(
    queue: MusicQueueState(
      items: items,
      order: const [1, 2, 0],
      cursor: index,
      shuffled: true,
      repeatMode: MusicRepeatMode.all,
    ),
    position: Duration(seconds: seconds),
    playing: playing,
  );
}

class _Session extends StubMusicPlaybackService implements MusicDeviceSession {
  _Session(this.snapshot);
  MusicTransferSnapshot? snapshot;
  MusicDevicePlayback? output;
  int revision = 0;
  int opens = 0;
  bool rejectPrepare = false;
  bool rejectCommit = false;

  @override
  MusicPlaybackService get playback => this;
  @override
  MusicDevicePlayback? get musicDeviceOutput => output;
  @override
  void setMusicDeviceOutput(MusicDevicePlayback? output) => this.output = output;
  double deviceVolume = 70;
  @override
  double get volume => deviceVolume;
  @override
  Future<void> setVolume(double value, {bool persist = true}) async => deviceVolume = value;
  @override
  Future<void> pause() async {
    revision++;
    snapshot = snapshot?.at(snapshot!.position, playing: false);
  }

  @override
  Future<void> play() async {
    revision++;
    snapshot = snapshot?.at(snapshot!.position, playing: true);
  }

  @override
  Future<void> resumeFrozenMusicDevice() => play();
  @override
  MusicTransferOffer? offerTransfer() =>
      snapshot == null || output != null ? null : MusicTransferOffer(snapshot!, revision, revision, revision, revision);
  @override
  Future<bool> finishTransfer(MusicTransferOffer offer) async {
    if (offer.generation != revision) return false;
    if (offer.snapshot.playing) await pause();
    return true;
  }

  @override
  Future<bool> acceptTransfer(MusicTransferSnapshot value, {bool Function()? current}) async {
    snapshot = value;
    revision++;
    opens++;
    return true;
  }

  @override
  Future<PreparedMusicDeviceTransfer?> prepareMusicDeviceTransfer(
    MusicTransferSnapshot value, {
    required bool Function() current,
    bool allowRemoteOutput = false,
  }) async {
    if (rejectPrepare || !current()) return null;
    final captured = revision;
    return (position, play) async {
      if (rejectCommit || !current() || revision != captured) return false;
      return acceptTransfer(value.at(position, playing: play));
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('handoff and return use the receiver current cursor and playhead', () async {
    final here = _Session(_queue());
    final there = _Session(null);
    final local = MusicDeviceEndpoint(here, allowed: () => true);
    final remote = MusicDeviceEndpoint(there, allowed: () => true);
    final link = MusicDeviceLink(name: 'Living room', request: remote.handle, isConnected: () => true);
    final controller = MusicDeviceController(local, here);
    addTearDown(() {
      controller.dispose();
      link.dispose();
      remote.close();
      here.dispose();
      there.dispose();
    });

    expect(await controller.moveTo(link), MusicDeviceMoveResult.completed);
    expect(here.snapshot!.playing, isFalse);
    expect(there.snapshot!.playing, isTrue);
    expect(there.snapshot!.queue.order, [1, 2, 0]);
    there.snapshot = _queue(index: 2, seconds: 88);
    there.revision++;

    expect(await controller.moveTo(null), MusicDeviceMoveResult.completed);
    expect(there.snapshot!.playing, isFalse);
    expect(here.snapshot!.queue.cursor, 2);
    expect(here.snapshot!.position, const Duration(seconds: 88));
    expect(here.snapshot!.playing, isTrue);
    expect(controller.active, isNull);
  });

  test('preflight denial and definite commit rejection preserve source playback', () async {
    final here = _Session(_queue());
    final there = _Session(null)..rejectPrepare = true;
    final local = MusicDeviceEndpoint(here, allowed: () => true);
    final remote = MusicDeviceEndpoint(there, allowed: () => true);
    final link = MusicDeviceLink(name: 'Receiver', request: remote.handle, isConnected: () => true);
    final controller = MusicDeviceController(local, here);
    addTearDown(() {
      controller.dispose();
      link.dispose();
      remote.close();
      here.dispose();
      there.dispose();
    });
    expect(await controller.moveTo(link), MusicDeviceMoveResult.rejected);
    expect(here.snapshot!.playing, isTrue);
    expect(there.opens, 0);
    there.rejectPrepare = false;
    there.rejectCommit = true;
    expect(await controller.moveTo(link), MusicDeviceMoveResult.rejected);
    expect(here.snapshot!.playing, isTrue);
    expect(controller.active, isNull);
  });

  test('a lost commit response is reconciled without opening twice', () async {
    final here = _Session(_queue());
    final there = _Session(null);
    final local = MusicDeviceEndpoint(here, allowed: () => true);
    final remote = MusicDeviceEndpoint(there, allowed: () => true);
    var dropped = false;
    Future<MusicConnectMessage?> request(MusicConnectMessage message) async {
      final reply = await remote.handle(message);
      if (message['op'] == 'commit' && !dropped) {
        dropped = true;
        return null;
      }
      return reply;
    }

    final link = MusicDeviceLink(name: 'Receiver', request: request, isConnected: () => true);
    final controller = MusicDeviceController(local, here);
    addTearDown(() {
      controller.dispose();
      link.dispose();
      remote.close();
      here.dispose();
      there.dispose();
    });
    expect(await controller.moveTo(link), MusicDeviceMoveResult.completed);
    expect(there.opens, 1);
    expect(here.snapshot!.playing, isFalse);
  });

  test('an unknown commit retains a paused queue and reconciles without duplicate playback', () async {
    final here = _Session(_queue());
    final there = _Session(null);
    final local = MusicDeviceEndpoint(here, allowed: () => true);
    final remote = MusicDeviceEndpoint(there, allowed: () => true);
    var partitioned = false;
    Future<MusicConnectMessage?> request(MusicConnectMessage message) async {
      if (partitioned) return null;
      final reply = await remote.handle(message);
      if (message['op'] == 'commit') {
        partitioned = true;
        return null;
      }
      return reply;
    }

    final link = MusicDeviceLink(name: 'Receiver', request: request, isConnected: () => true);
    final controller = MusicDeviceController(local, here);
    addTearDown(() {
      controller.dispose();
      link.dispose();
      remote.close();
      here.dispose();
      there.dispose();
    });
    expect(await controller.moveTo(link), MusicDeviceMoveResult.uncertain);
    expect(here.snapshot!.playing, isFalse);
    expect(there.snapshot!.playing, isTrue);
    expect(there.opens, 1);
    expect(link.state?.track?.id, 'a');
    expect(link.state?.snapshot?.playing, isFalse);
    expect(link.connected, isFalse);
    partitioned = false;
    expect(await link.refresh(full: true), isTrue);
    expect(link.connected, isTrue);
    expect(link.state?.snapshot?.playing, isTrue);
    expect(there.opens, 1);
  });

  test('volume acknowledgement keeps the queue without retransmitting it', () async {
    final session = _Session(_queue());
    final endpoint = MusicDeviceEndpoint(session, allowed: () => true);
    MusicConnectMessage? lastReply;
    final link = MusicDeviceLink(
      name: 'Receiver',
      isConnected: () => true,
      request: (message) async => lastReply = await endpoint.handle(message),
    );
    addTearDown(() {
      link.dispose();
      endpoint.close();
      session.dispose();
    });
    expect(await link.refresh(full: true), isTrue);
    await link.control('volume', {'volume': 42});
    expect((lastReply?['state'] as Map).containsKey('queue'), isFalse);
    expect(link.state?.volume, 42);
    expect(link.state?.queue, hasLength(3));
  });

  test('stopping receiving invalidates prepared tickets before pairing rotation', () async {
    final session = _Session(null);
    final endpoint = MusicDeviceEndpoint(session, allowed: () => true);
    addTearDown(() {
      endpoint.close();
      session.dispose();
    });
    final ready = await endpoint.handle({'op': 'prepare', 'queue': _queue().toJson()});
    expect(ready?['ok'], isTrue);
    endpoint.reset();
    final reply = await endpoint.handle({'op': 'commit', 'ticket': ready?['ticket'], 'position': 31, 'playing': true});
    expect(reply?['ok'], isFalse);
    expect(session.opens, 0);
  });

  test('a newer receiver edit rejects an old controller command', () async {
    final session = _Session(_queue());
    final endpoint = MusicDeviceEndpoint(session, allowed: () => true);
    addTearDown(() {
      endpoint.close();
      session.dispose();
    });
    final state = await endpoint.handle({'op': 'state'});
    session.revision++;
    final result = await endpoint.handle({
      'op': 'control',
      'revision': state!['revision'],
      'action': 'pause',
      'args': <String, dynamic>{},
    });
    expect(result!['ok'], isFalse);
    expect(session.snapshot!.playing, isTrue);
  });
}
