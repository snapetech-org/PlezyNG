import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import '../../mpv/player/music_pcm_capture_source.dart';
import 'caldera_group.dart';
import 'xita_packet.dart';
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
  });
  final MusicPcmCaptureSource capture;
  final Duration position;
  final double gain;
  final bool playing;
  final Future<bool> Function() readMuted;
  final Future<void> Function(bool) setMuted;
}

abstract interface class NativeMusicGroupSourceControls {
  bool get sendingNativeMusicGroup;
  Future<void> sendNativeMusicGroup(List<CalderaNode> sinks, {required bool Function() current});
}

/// Explicit native audio source. Only selected, version-checked private peers
/// receive PCM. Every native sink gets identical frames from one monotonic
/// clock. Local decoder AO is muted while the group is the selected output.
class CalderaAudioSource {
  CalderaAudioSource({required List<CalderaNode> sinks, required this.feeds, required this.current, this.onClosed})
    : sinks = List.unmodifiable(sinks);
  final List<CalderaNode> sinks;
  final List<CalderaPcmFeed> Function() feeds;
  final bool Function() current;
  final void Function()? onClosed;
  final id = const Uuid().v4();
  final _mixer = XitaPcmMixer();
  final _clock = Stopwatch();
  final _peers = <_SourcePeer>[];
  final _leases = <MusicPcmCaptureSource, _CaptureLease>{};
  RawDatagramSocket? _udp;
  Timer? _timer;
  Future<void>? _closing, _polling;
  bool _closed = false, _started = false;
  int _lastPoll = 0, _epoch = 0, _period = 0, _lastPing = 0;
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
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      if (!_valid) throw StateError('Native music scope changed');
      _udp!.listen((_) {}, onError: (Object _) => unawaited(close()));
      _clock.start();
      for (final node in sinks) {
        if (!_valid) throw StateError('Native music scope changed');
        final http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
        // Ownership transfers to _peers; _close retires every registered socket.
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
        final peer = _SourcePeer(socket);
        _peers.add(peer);
        unawaited(peer.ready.future.then<void>((_) {}, onError: (Object _) {}));
        unawaited(peer.accepted.future.then<void>((_) {}, onError: (Object _) {}));
        if (!_valid) throw StateError('Native music scope changed');
        socket.pingInterval = const Duration(seconds: 2);
        socket.listen(
          (frame) {
            try {
              if (!_valid || frame is! String) throw const FormatException('Invalid native mesh');
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
                  if (peer.joined &&
                      const ['SetState', 'SetNodeState'].contains(value['method']) &&
                      data['source'] != id) {
                    unawaited(close());
                  } else if (peer.joined && data['source'] == id && !peer.accepted.isCompleted) {
                    peer.accepted.complete();
                  }
                }
              }
            } catch (_) {
              unawaited(close());
            }
          },
          onDone: () => unawaited(close()),
          onError: (Object _) => unawaited(close()),
        );
        _send(peer, 'Hello', {'capabilities': null, 'version': '1.0.0'});
        await peer.ready.future.timeout(const Duration(seconds: 5));
        if (!_valid) throw StateError('Native music scope changed');
      }
      final membership = {
        'source': id,
        'sinks': [id, ...sinks.map((node) => node.id)],
      };
      for (final peer in _peers) {
        _send(peer, 'SetSinksForSource', membership);
        _send(peer, 'SetState', {'capabilities': null, 'version': '1.0.0', 'source': id, 'volume': 100});
        peer.joined = true;
      }
      await Future.wait(_peers.map((peer) => peer.accepted.future)).timeout(const Duration(seconds: 5));
      if (!_valid) throw StateError('Native music scope changed');
      final initial = _poll();
      _polling = initial;
      try {
        await initial;
      } finally {
        if (identical(_polling, initial)) _polling = null;
      }
      if (!_valid || _leases.isEmpty) throw StateError('Music PCM capture unavailable');
      _epoch = _clock.elapsedMicroseconds + 100000;
      _started = true;
      _timer = Timer.periodic(const Duration(milliseconds: 5), (_) => _tick());
    } catch (_) {
      await close();
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
      await prepareFeed(feed);
      if (_leases[feed.capture]?.enabled != true) continue;
      if (!_valid) return;
      final blocks = await feed.capture.drainMusicPcmCapture();
      if (!_valid) return;
      if (blocks.length > 32) throw const FormatException('Music PCM batch too large');
      if (!feed.playing) {
        _mixer.remove(feed.capture);
        continue;
      }
      for (final block in blocks) {
        _mixer.add(feed.capture, block, position: feed.position, gain: feed.gain);
      }
    }
    final retired = _leases.keys.where((key) => !sources.any((feed) => identical(feed.capture, key))).toList();
    for (final key in retired) {
      await _release(_leases.remove(key)!);
    }
    _lastPoll = _clock.elapsedMilliseconds;
  }

  void _tick() {
    if (!_valid ||
        _clock.elapsedMilliseconds - _lastPoll > 3000 ||
        _peers.any((peer) => _clock.elapsedMilliseconds - peer.lastMessage > 15000)) {
      unawaited(close());
      return;
    }
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
      for (final peer in _peers) {
        peer.socket.add('{"data":"ping"}');
      }
    }
    final elapsed = _clock.elapsedMicroseconds - _epoch;
    if (elapsed < 0) return;
    final due = elapsed * XitaPcmMixer.sampleRate ~/ 1000000;
    if (due - _mixer.cursor > XitaPcmMixer.sampleRate ~/ 4) {
      unawaited(close()); // Never replay a stalled clock in an unbounded burst.
      return;
    }
    var budget = 2;
    try {
      while (budget-- > 0 && due >= _mixer.cursor) {
        final frame = _mixer.cursor;
        // Repeated descriptors permit recovery without changing format or clock.
        if (_period++ % 16 == 0) {
          _broadcast(
            XitaDescriptor.encode(
              sampleRate: XitaPcmMixer.sampleRate,
              channels: 2,
              periodFrames: _periodFrames,
              frame: frame,
              timestamp: DateTime.now().toUtc(),
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
              transmitDelayMicros: (_clock.elapsedMicroseconds - _epoch - frame * 1000000 ~/ XitaPcmMixer.sampleRate)
                  .clamp(0, 1000000),
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
    _udp?.close();
    _udp = null;
    for (final peer in _peers) {
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
  _SourcePeer(this.socket);
  final WebSocket socket;
  final ready = Completer<void>();
  final accepted = Completer<void>();
  int lastMessage = 0;
  bool joined = false;
}

class _CaptureLease {
  _CaptureLease(this.feed);
  final CalderaPcmFeed feed;
  Future<void>? attaching;
  bool mutedBefore = false, enabled = false, muted = false;
}
