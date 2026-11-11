import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import '../../mpv/player/music_pcm_capture_source.dart';
import 'caldera_group.dart';
import 'caldera_source_endpoint.dart';
import 'xita_packet.dart';
import 'xita_transmit_clock.dart';
import 'xita_pcm_mixer.dart';

/// A live decoder lease supplied by the shared session. Volume/EQ and listen
/// reporting remain with that session; no second media-server stream is opened.
class CalderaPcmFeed {
  const CalderaPcmFeed({
    required this.capture,
    required this.position,
    required this.gain,
    required this.playing,
    required this.readMuted,
    required this.setMuted,
    this.readGain,
    this.current,
  });
  final MusicPcmCaptureSource capture;
  final Duration position;
  final double gain;
  final bool playing;
  final Future<bool> Function() readMuted;
  final Future<void> Function(bool) setMuted;
  final Future<double> Function()? readGain;
  final bool Function()? current;
}

abstract interface class NativeMusicGroupSourceControls {
  bool get sendingNativeMusicGroup;
  Future<void> sendNativeMusicGroup(List<CalderaNode> sinks, {required bool Function() current});
}

/// Explicit native audio source. Only selected, version-checked private peers
/// receive PCM. Every native sink gets identical frames from one monotonic
/// clock. Local decoder AO is muted while the group is the selected output.
class CalderaAudioSource {
  CalderaAudioSource({
    required List<CalderaNode> sinks,
    required this.feeds,
    required this.current,
    this.onClosed,
    this.onMembershipChanged,
    this.metadata,
    this.control,
    this.serveCompanion = true,
    String? id,
  }) : _sinks = List.unmodifiable(sinks),
       id = id ?? const Uuid().v4();
  List<CalderaNode> _sinks;
  List<CalderaNode> get sinks => _sinks;
  final List<CalderaPcmFeed> Function() feeds;
  final bool Function() current;
  final void Function()? onClosed, onMembershipChanged;
  final CalderaSourceMetadata Function()? metadata;
  final Future<void> Function(String action, int? value)? control;
  CalderaSourceEndpoint? _endpoint;
  final String id;
  final bool serveCompanion;
  final _mixer = XitaPcmMixer();
  final _clock = Stopwatch();
  final _peers = <_SourcePeer>[];
  final _leases = <MusicPcmCaptureSource, _CaptureLease>{};
  RawDatagramSocket? _udp;
  Timer? _timer;
  Future<void>? _closing, _polling, _changing;
  bool _closed = false, _started = false;
  int _lastPoll = 0, _period = 0, _lastPing = 0;
  XitaTransmitClock? _sendClock;
  static const _periodFrames = 1024;
  bool get active => _started && _valid;
  bool get _valid => !_closed && current();

  void _send(_SourcePeer peer, String method, Object data) {
    peer.socket.add(
      jsonEncode({'method': method, 'data': data, 'source': id, 'sentAt': DateTime.now().millisecondsSinceEpoch}),
    );
  }

  Future<void> start() async {
    if (_started ||
        _closed ||
        !current() ||
        sinks.isEmpty ||
        sinks.length > 8 ||
        sinks.any((node) => !CalderaNode.privateAddress(node.address)) ||
        sinks.map((node) => node.id).toSet().length != sinks.length ||
        sinks.map((node) => node.address.address).toSet().length != sinks.length) {
      throw StateError('Native audio output unavailable');
    }
    try {
      final initialFeeds = feeds();
      if (initialFeeds.isEmpty || initialFeeds.length > 2) throw StateError('No local music decoders');
      for (final feed in initialFeeds) {
        if (!await feed.capture.musicPcmCaptureAvailable() || !_valid) {
          throw StateError('Music PCM capture unavailable');
        }
      }
      if (serveCompanion && metadata != null) {
        final readMetadata = metadata!;
        final handleControl = control;
        if (handleControl == null) throw StateError('Native source control unavailable');
        _endpoint = CalderaSourceEndpoint(
          id: id,
          peers: const {},
          allowsPeer: (address) => sinks.any((node) => node.address.address == address.address),
          metadata: readMetadata,
          control: handleControl,
          current: () => _valid,
        );
        await _endpoint!.start();
        if (!_valid) throw StateError('Native music scope changed');
      }
      final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      if (!_valid) {
        udp.close();
        throw StateError('Native music scope changed');
      }
      _udp = udp;
      _udp!.listen((_) {}, onError: (Object _) => unawaited(close()));
      _clock.start();
      _validateSinks(sinks);
      final initialPeers = <_SourcePeer>[];
      for (final node in sinks) {
        initialPeers.add(await _connect(node));
      }
      for (final peer in initialPeers) {
        _join(peer, sinks);
      }
      await Future.wait(initialPeers.map((peer) => peer.accepted.future)).timeout(const Duration(seconds: 5));
      if (!_valid || initialPeers.any((peer) => peer.retired)) throw StateError('Native music scope changed');
      for (final peer in initialPeers) {
        peer.adopted = true;
      }
      final initial = _poll();
      _polling = initial;
      try {
        await initial;
      } finally {
        if (identical(_polling, initial)) _polling = null;
      }
      if (!_valid || _leases.isEmpty) throw StateError('Music PCM capture unavailable');
      _sendClock = XitaTransmitClock(
        startMicros: _clock.elapsedMicroseconds + 100000,
        timestamp: DateTime.now().toUtc().add(const Duration(milliseconds: 100)),
      );
      _started = true;
      _timer = Timer.periodic(const Duration(milliseconds: 5), (_) => _tick());
    } catch (_) {
      await close();
      rethrow;
    }
  }

  static bool _sameNode(CalderaNode a, CalderaNode b) =>
      a.id == b.id &&
      a.address.address == b.address.address &&
      a.meshPort == b.meshPort &&
      a.companionPort == b.companionPort;

  static void _validateSinks(List<CalderaNode> nodes) {
    if (nodes.isEmpty ||
        nodes.length > 8 ||
        nodes.any(
          (node) =>
              !CalderaNode.privateAddress(node.address) ||
              !RegExp(r'^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$').hasMatch(node.id),
        ) ||
        nodes.map((node) => node.id).toSet().length != nodes.length ||
        nodes.map((node) => node.address.address).toSet().length != nodes.length) {
      throw ArgumentError('Invalid native audio sinks');
    }
  }

  Map<String, Object> _membership(List<CalderaNode> nodes) => {
    'source': id,
    'sinks': [id, ...nodes.map((node) => node.id)],
  };

  void _join(_SourcePeer peer, List<CalderaNode> nodes) {
    peer.joined = true;
    _send(peer, 'SetSinksForSource', _membership(nodes));
    _send(peer, 'SetState', {'capabilities': null, 'version': '1.0.0', 'source': id, 'volume': 100});
  }

  void _retirePeer(_SourcePeer peer) {
    if (peer.retired) return;
    peer.retired = true;
    _peers.remove(peer);
    if (!peer.ready.isCompleted) peer.ready.completeError(StateError('Native peer disconnected'));
    if (!peer.accepted.isCompleted) peer.accepted.completeError(StateError('Native peer disconnected'));
    unawaited(peer.socket.close());
    if (!_valid || !peer.adopted) return;
    _sinks = List.unmodifiable(sinks.where((node) => !_sameNode(node, peer.node)));
    if (sinks.isEmpty) {
      unawaited(close());
    } else {
      for (final remaining in _peers.where((peer) => peer.adopted).toList()) {
        _send(remaining, 'SetSinksForSource', _membership(sinks));
      }
      onMembershipChanged?.call();
    }
  }

  Future<_SourcePeer> _connect(CalderaNode node, {bool Function()? selecting}) async {
    bool valid() => _valid && selecting?.call() != false;
    if (!valid()) throw StateError('Native music selection changed');
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    // Ownership transfers to _peers after the asynchronous connection is checked.
    // ignore: close_sinks
    late final WebSocket socket;
    try {
      socket = await WebSocket.connect(
        'ws://${node.address.address}:${node.meshPort}/',
        customClient: http,
      ).timeout(const Duration(seconds: 5));
    } finally {
      http.close();
    }
    if (!valid()) {
      unawaited(socket.close());
      throw StateError('Native music selection changed');
    }
    final peer = _SourcePeer(socket, node);
    _peers.add(peer);
    unawaited(peer.ready.future.then<void>((_) {}, onError: (Object _) {}));
    unawaited(peer.accepted.future.then<void>((_) {}, onError: (Object _) {}));
    socket.pingInterval = const Duration(seconds: 2);
    socket.listen(
      (frame) {
        try {
          if (!_valid || peer.retired || frame is! String) throw const FormatException('Invalid native mesh');
          for (final value in CalderaGroupClient.meshMessages(frame)) {
            if (value['data'] == 'ping') {
              peer.lastMessage = _clock.elapsedMilliseconds;
              continue;
            }
            if (value['source'] != node.id) throw const FormatException('Native identity changed');
            peer.lastMessage = _clock.elapsedMilliseconds;
            if (const ['Hello', 'SetState', 'SetNodeState'].contains(value['method'])) {
              final data = value['data'];
              if (data is! Map || data['version'] != '1.0.0') {
                throw const FormatException('Unsupported native peer');
              }
              if (!peer.ready.isCompleted) peer.ready.complete();
              if (peer.joined && const ['SetState', 'SetNodeState'].contains(value['method']) && data['source'] != id) {
                _retirePeer(peer);
                return;
              }
              if (peer.joined && data['source'] == id && !peer.accepted.isCompleted) peer.accepted.complete();
            }
          }
        } catch (_) {
          _retirePeer(peer);
        }
      },
      onDone: () => _retirePeer(peer),
      onError: (Object _) => _retirePeer(peer),
    );
    try {
      _send(peer, 'Hello', {'capabilities': null, 'version': '1.0.0'});
      await peer.ready.future.timeout(const Duration(seconds: 5));
      if (!valid() || peer.retired) throw StateError('Native music selection changed');
      return peer;
    } catch (_) {
      _retirePeer(peer);
      rethrow;
    }
  }

  /// Keep decoder leases, source UDP port and frame clock while changing outputs.
  /// New peers receive nothing until their ownership acknowledgement arrives.
  Future<void> replaceSinks(List<CalderaNode> nodes, {required bool Function() current}) async {
    _validateSinks(nodes);
    if (!active || !current() || _changing != null) throw StateError('Native output update unavailable');
    if (nodes.length == sinks.length && nodes.every((node) => sinks.any((old) => _sameNode(node, old)))) return;
    final task = _replaceSinks(List.unmodifiable(nodes), current);
    _changing = task;
    try {
      await task;
    } finally {
      if (identical(_changing, task)) _changing = null;
    }
  }

  Future<void> _replaceSinks(List<CalderaNode> nodes, bool Function() current) async {
    final added = <_SourcePeer>[];
    final retained = _peers.where((peer) => peer.adopted && nodes.any((node) => _sameNode(node, peer.node))).toList();
    bool owns() => active && current();
    try {
      for (final node in nodes) {
        if (!owns()) throw StateError('Native output selection changed');
        if (retained.any((peer) => _sameNode(peer.node, node))) continue;
        final peer = await _connect(node, selecting: current);
        added.add(peer);
        _join(peer, nodes);
        await peer.accepted.future.timeout(const Duration(seconds: 5));
        if (!owns() || peer.retired) throw StateError('Native output selection changed');
      }
      if (!owns() || retained.any((peer) => peer.retired)) throw StateError('Native output selection changed');
      final removed = _peers.where((peer) => peer.adopted && !retained.contains(peer)).toList();
      // Commit the destination set atomically before notifying or closing peers.
      _sinks = nodes;
      for (final peer in added) {
        peer.adopted = true;
      }
      for (final peer in [...retained, ...added]) {
        _send(peer, 'SetSinksForSource', _membership(nodes));
      }
      for (final peer in removed) {
        peer.adopted = false;
        _send(peer, 'SetSinksForSource', _membership(nodes));
        _retirePeer(peer);
      }
      _period = 0; // Advertise the existing timeline before any new destination gets PCM.
      onMembershipChanged?.call();
    } catch (_) {
      for (final peer in added) {
        if (owns() && !peer.retired) _send(peer, 'SetSinksForSource', _membership(sinks));
        peer.adopted = false;
        _retirePeer(peer);
      }
      rethrow;
    }
  }

  Future<void> prepareFeed(CalderaPcmFeed feed) async {
    if (!_valid) return;
    final existing = _leases[feed.capture];
    if (existing != null) {
      await existing.attaching;
      return;
    }
    final lease = _CaptureLease(feed);
    _leases[feed.capture] = lease;
    final pending = _attach(lease);
    lease.attaching = pending;
    await pending;
  }

  Future<void> _attach(_CaptureLease lease) async {
    final feed = lease.feed, capture = feed.capture;
    if (!await capture.musicPcmCaptureAvailable()) throw StateError('Music PCM capture unavailable');
    if (!_valid) throw StateError('Native music scope changed');
    lease.mutedBefore = await feed.readMuted();
    if (!_valid) throw StateError('Native music scope changed');
    if (!await capture.setMusicPcmCaptureEnabled(true)) throw StateError('Music PCM capture rejected');
    lease.enabled = true;
    if (!_valid) {
      await _release(lease);
      throw StateError('Native music scope changed');
    }
    await feed.setMuted(true);
    lease.muted = true;
    if (!_valid) await _release(lease);
  }

  Future<void> _release(_CaptureLease lease) async {
    final enabled = lease.enabled, muted = lease.muted;
    lease.enabled = false;
    lease.muted = false;
    try {
      if (enabled) await lease.feed.capture.setMusicPcmCaptureEnabled(false);
    } finally {
      if (muted) await lease.feed.setMuted(lease.mutedBefore);
    }
  }

  Future<void> _poll() async {
    if (!_valid) return;
    final sources = feeds();
    if (sources.isEmpty || sources.length > 2 || sources.map((feed) => feed.capture).toSet().length != sources.length) {
      throw StateError('Native music decoder ownership changed');
    }
    for (final feed in sources) {
      if (!_valid) return;
      if (feed.current?.call() == false) continue;
      try {
        await prepareFeed(feed);
        if (_leases[feed.capture]?.enabled != true) continue;
        if (!_valid) return;
        if (feed.current?.call() == false) continue;
        final blocks = await feed.capture.drainMusicPcmCapture();
        if (!_valid) return;
        if (blocks.length > 32) throw const FormatException('Music PCM batch too large');
        if (!feed.playing) {
          _mixer.remove(feed.capture);
          continue;
        }
        final gain = feed.gain * (await feed.readGain?.call() ?? 1);
        if (!_valid) return;
        if (feed.current?.call() == false) {
          _mixer.remove(feed.capture);
          continue;
        }
        _mixer.setGain(feed.capture, gain);
        for (final block in blocks) {
          _mixer.add(feed.capture, block, position: feed.position, gain: gain);
        }
      } catch (_) {
        if (!_valid) return;
        if (feed.current?.call() == false) {
          _mixer.remove(feed.capture);
          continue;
        }
        rethrow;
      }
    }
    final retired = _leases.keys.where((key) => !sources.any((feed) => identical(feed.capture, key))).toList();
    for (final key in retired) {
      await _release(_leases.remove(key)!);
    }
    _lastPoll = _clock.elapsedMilliseconds;
  }

  void _tick() {
    if (!_valid || _clock.elapsedMilliseconds - _lastPoll > 3000) {
      unawaited(close());
      return;
    }
    for (final peer in _peers.where((peer) => peer.adopted).toList()) {
      if (_clock.elapsedMilliseconds - peer.lastMessage > 15000) _retirePeer(peer);
    }
    if (!_valid) return;
    if (_polling == null) {
      final pending = _poll();
      _polling = pending;
      unawaited(
        pending.then<void>(
          (_) {
            if (identical(_polling, pending)) _polling = null;
          },
          onError: (Object _) {
            if (identical(_polling, pending)) _polling = null;
            unawaited(close());
          },
        ),
      );
    }
    if (_clock.elapsedMilliseconds - _lastPing > 2000) {
      _lastPing = _clock.elapsedMilliseconds;
      for (final peer in _peers.toList()) {
        if (peer.socket.readyState != WebSocket.open) {
          _retirePeer(peer);
          continue;
        }
        peer.socket.add('{"data":"ping"}');
      }
    }
    final clock = _sendClock;
    if (clock == null) return;
    var budget = 2;
    try {
      while (budget-- > 0 && clock.due(_clock.elapsedMicroseconds)) {
        final scheduled = clock.nextMicros;
        final delay = clock.lateness(_clock.elapsedMicroseconds);
        clock.advance(_clock.elapsedMicroseconds, bufferedFrames: _mixer.bufferedFrames);
        final frame = _mixer.cursor;
        // Repeated descriptors permit recovery without changing format or clock.
        if (_period++ % 16 == 0) {
          _broadcast(
            XitaDescriptor.encode(
              sampleRate: XitaPcmMixer.sampleRate,
              channels: 2,
              periodFrames: _periodFrames,
              frame: frame,
              timestamp: clock.timestampAt(scheduled),
            ),
          );
        }
        final pcm = _mixer.render(_periodFrames);
        const packetFrames = 128;
        for (var offset = 0; offset < _periodFrames; offset += packetFrames) {
          _broadcast(
            XitaAudio.encode(
              frame: frame + offset,
              channels: 2,
              samples: Float32List.sublistView(pcm, offset * 2, (offset + packetFrames) * 2),
              flags: offset == 0 ? 1 : 0,
              transmitDelayMicros: delay,
            ),
          );
        }
      }
    } catch (_) {
      unawaited(close());
    }
  }

  void _broadcast(Uint8List packet) {
    if (!_valid) return;
    for (final node in sinks) {
      _udp?.send(packet, node.address, 5000);
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _started = false;
    _timer?.cancel();
    await _endpoint?.close();
    _endpoint = null;
    _udp?.close();
    _udp = null;
    for (final peer in _peers.toList()) {
      peer.retired = true;
      if (!peer.ready.isCompleted) peer.ready.completeError(StateError('Native audio closed'));
      if (!peer.accepted.isCompleted) peer.accepted.completeError(StateError('Native audio closed'));
      unawaited(peer.socket.close());
    }
    final pending = _polling;
    if (pending != null) {
      try {
        await pending.timeout(const Duration(seconds: 3));
      } on Object {
        /* Retired below. */
      }
    }
    for (final lease in _leases.values.toList()) {
      try {
        await _release(lease);
      } on Object {
        /* Native player teardown owns stale leases. */
      }
    }
    _leases.clear();
    _mixer.clear();
    onClosed?.call();
  }
}

class _SourcePeer {
  _SourcePeer(this.socket, this.node);
  final CalderaNode node;
  final WebSocket socket;
  final ready = Completer<void>();
  final accepted = Completer<void>();
  int lastMessage = 0;
  bool joined = false, adopted = false, retired = false;
}

class _CaptureLease {
  _CaptureLease(this.feed);
  final CalderaPcmFeed feed;
  Future<void>? attaching;
  bool mutedBefore = false, enabled = false, muted = false;
}
