import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'caldera_group.dart';
import 'caldera_mesh_volume.dart';
import 'caldera_mesh_equalizer.dart';
import 'caldera_state_feed.dart';
import 'xita_packet.dart';
import 'caldera_audio_output.dart';
import 'xita_audio_renderer.dart';
export 'caldera_audio_output.dart';
export 'xita_jitter_buffer.dart';

abstract interface class NativeMusicGroupControls {
  bool get receivingNativeMusicGroup;
  Future<void> receiveNativeMusicGroup(CalderaNode leader, {required bool Function() current});
  Future<void> leaveNativeMusicGroup();
}

/// An explicitly selected native peer is the sole allowed UDP and mesh source.
/// No Plex credentials, raw library data or write authority cross this channel.
class CalderaAudioSink {
  CalderaAudioSink({required this.leader, required this.output, required this.current, this.onClosed, String? id})
    : id = id ?? const Uuid().v4();
  final CalderaNode leader;
  final CalderaAudioOutput output;
  final bool Function() current;
  final String id;
  final void Function()? onClosed;
  final _owner = Object();
  final _clock = Stopwatch()..start();
  RawDatagramSocket? _udp;
  WebSocket? _mesh;
  Timer? _heartbeat;
  CalderaStateFeed? _stateFeed;
  final _controller = CalderaGroupClient();
  CalderaNowPlaying? _state;
  bool _suspended = false, _joined = false;
  int _queuedControls = 0;
  Future<void> _controls = Future.value();
  XitaAudioRenderer? _renderer;
  final _descriptorReady = Completer<XitaDescriptor>();
  final _meshReady = Completer<void>();
  bool _closed = false, _opened = false, _opening = false;
  int? _sourcePort;
  int _lastAudio = 0, _lastMesh = 0;
  bool get active => !_closed && _opened && output.ownsCalderaAudio(_owner);
  bool get _valid => !_closed && current() && (!_opened || output.ownsCalderaAudio(_owner));

  late final _equalizerCommands = output is CalderaEqualizerControls
      ? CalderaMeshEqualizer(output as CalderaEqualizerControls)
      : null;
  void _publishSettings() => _send('SetNodeState', {
    ..._volumeCommands.state(leader.id),
    if (output case final CalderaEqualizerControls eq) 'equalizer': CalderaMeshEqualizer.snapshot(eq.calderaEqualizer),
  });

  late final _volumeCommands = CalderaMeshVolume(
    read: () => output is CalderaAudioVolumeOutput ? (output as CalderaAudioVolumeOutput).calderaAudioVolume : 100,
    write: (value) async {
      if (output case final CalderaAudioVolumeOutput volume) {
        if (!_opened || !output.ownsCalderaAudio(_owner)) throw StateError('Native output unavailable');
        await volume.setCalderaAudioVolume(_owner, value);
      } else {
        throw UnsupportedError('Native output volume unavailable');
      }
    },
  );

  bool get _silent => _suspended || _state?.snapshot.state != 'playing';

  void _resetTimeline() {
    _renderer?.reset();
    _lastAudio = _clock.elapsedMilliseconds;
  }

  void _publishMetadata() {
    if (!_valid || !_opened) return;
    if (output case final CalderaAudioMetadataOutput metadata) {
      final state = _state;
      if (state != null) metadata.updateCalderaMetadata(_owner, state);
    }
  }

  /// The native source keeps queue authority. Revalidate its Companion identity
  /// for every serialized command; a local pause must not stall the WAV socket.
  Future<void> control(String action, {Duration? position}) {
    final state = _state;
    if (!active || state == null || _queuedControls >= 32) {
      return Future.error(StateError('Native source control unavailable'));
    }
    _queuedControls++;
    final command = _controls.then((_) async {
      bool owns() => active && _valid && _state?.snapshot.player == state.snapshot.player;
      if (!owns()) throw StateError('Native source changed');
      if (action == 'seek') {
        if (position == null) throw ArgumentError('Native seek is missing');
        final maximum = state.snapshot.duration;
        final millis = position.inMilliseconds.clamp(0, maximum > 0 ? maximum : 86400000);
        await _controller.seek(leader, state.snapshot, Duration(milliseconds: millis), current: owns);
      } else {
        await _controller.transport(leader, state.snapshot, action, current: owns);
      }
    });
    _controls = command.then<void>((_) {}, onError: (Object _) {});
    return command.whenComplete(() => _queuedControls--);
  }

  void _send(String method, Object data) => _mesh?.add(
    jsonEncode({'method': method, 'data': data, 'source': id, 'sentAt': DateTime.now().millisecondsSinceEpoch}),
  );

  Future<void> start() async {
    if (_closed || _opening || _opened || !current() || !CalderaNode.privateAddress(leader.address)) {
      throw StateError('Native audio source unavailable');
    }
    _opening = true;
    // Attach handlers before any asynchronous bind can fail.
    unawaited(_descriptorReady.future.then<void>((_) {}, onError: (Object _) {}));
    unawaited(_meshReady.future.then<void>((_) {}, onError: (Object _) {}));
    try {
      final feed = CalderaStateFeed(
        node: leader,
        current: () => _valid,
        changed: (state) {
          final wasSilent = _silent;
          _state = state;
          if (wasSilent != _silent) _resetTimeline();
          _publishMetadata();
        },
        failed: () => unawaited(close()),
      );
      _stateFeed = feed;
      await feed.start();
      if (!_valid) throw StateError('Native audio scope changed');
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 5000);
      if (!_valid) throw StateError('Native audio scope changed');
      _udp!.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? datagram;
        var budget = 256;
        while (budget-- > 0 && (datagram = _udp?.receive()) != null) {
          final packet = datagram!;
          if (!_valid ||
              packet.address.address != leader.address.address ||
              _sourcePort != null && packet.port != _sourcePort) {
            continue;
          }
          final decoded = XitaPacket.decode(packet.data);
          if (decoded is XitaDescriptor) {
            if (decoded.terminated) {
              unawaited(close());
              return;
            }
            if (_renderer != null &&
                (decoded.sampleRate != _renderer!.descriptor.sampleRate ||
                    decoded.channels != _renderer!.descriptor.channels ||
                    decoded.format != _renderer!.descriptor.format)) {
              unawaited(close());
              return;
            }
            if (_suspended != decoded.suspended) _resetTimeline();
            _suspended = decoded.suspended;
            _lastAudio = _clock.elapsedMilliseconds;
            _sourcePort ??= packet.port;
            _renderer ??= XitaAudioRenderer(
              descriptor: decoded,
              output: output,
              owner: _owner,
              current: () => _valid,
              silent: () => _silent,
              title: leader.name,
              monotonicMicros: () => _clock.elapsedMicroseconds,
              onClosed: () => unawaited(close()),
            );
            if (!_descriptorReady.isCompleted) _descriptorReady.complete(decoded);
          } else if (decoded is XitaAudio && _renderer != null) {
            if (decoded.format != _renderer!.descriptor.format || decoded.channels != _renderer!.descriptor.channels) {
              unawaited(close());
              return;
            }
            if (decoded.terminated) {
              unawaited(close());
              return;
            }
            if (_suspended != decoded.suspended) _resetTimeline();
            _suspended = decoded.suspended;
            _lastAudio = _clock.elapsedMilliseconds;
            if (!_silent) _renderer!.add(decoded);
          }
        }
      }, onError: (Object _) => unawaited(close()));
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      try {
        _mesh = await WebSocket.connect(
          'ws://${leader.address.address}:${leader.meshPort}/',
          customClient: client,
        ).timeout(const Duration(seconds: 5));
      } finally {
        client.close();
      }
      if (!_valid) throw StateError('Native audio scope changed');
      _mesh!.pingInterval = const Duration(seconds: 2);
      _lastMesh = _clock.elapsedMilliseconds;
      _mesh!.listen(
        (frame) {
          try {
            if (!_valid || frame is! String) throw const FormatException('Invalid native audio mesh');
            for (final message in CalderaGroupClient.meshMessages(frame)) {
              if (message['data'] == 'ping') {
                _lastMesh = _clock.elapsedMilliseconds;
                continue;
              }
              if (message['source'] != leader.id) throw const FormatException('Native peer identity changed');
              _lastMesh = _clock.elapsedMilliseconds;
              final data = message['data'];
              if (CalderaMeshEqualizer.supports(message['method'])) {
                final commands = _equalizerCommands;
                if (!_meshReady.isCompleted || commands == null) throw StateError('Native equalizer unavailable');
                final operation = commands.apply(
                  message['method'],
                  data,
                  current: () => _valid && _opened,
                  changed: _publishSettings,
                );
                unawaited(operation.catchError((Object _) => close()));
              }
              if (message['method'] == 'SetSinkVolume') {
                if (!_meshReady.isCompleted) throw const FormatException('Native Hello required');
                final operation = _volumeCommands.apply(data, current: () => _valid, changed: _publishSettings);
                unawaited(operation.catchError((Object _) => close()));
              }
              if (const ['Hello', 'SetState', 'SetNodeState'].contains(message['method'])) {
                if (data is! Map || data['version'] != '1.0.0') throw const FormatException('Unsupported native peer');
                if (!_meshReady.isCompleted) _meshReady.complete();
              }
              if (_joined &&
                  const ['SetState', 'SetNodeState'].contains(message['method']) &&
                  data is Map &&
                  data['source'] != leader.id) {
                unawaited(close());
                return;
              }
            }
          } catch (_) {
            unawaited(close());
          }
        },
        onDone: () => unawaited(close()),
        onError: (Object _) => unawaited(close()),
      );
      _send('Hello', {'capabilities': null, 'version': '1.0.0'});
      await _meshReady.future.timeout(const Duration(seconds: 5));
      if (!_valid) throw StateError('Native audio scope changed');
      _joined = true;
      _send('SetSinksForSource', {
        'source': leader.id,
        'sinks': [leader.id, id],
      });
      await _descriptorReady.future.timeout(const Duration(seconds: 5));
      if (!_valid) throw StateError('Native audio scope changed');
      _heartbeat = Timer.periodic(const Duration(milliseconds: 500), (_) {
        final now = _clock.elapsedMilliseconds;
        if (!_valid || !_silent && now - _lastAudio > 5000 || now - _lastMesh > 15000) {
          unawaited(close());
          return;
        }
        _mesh?.add('{"data":"ping"}');
      });
      await _renderer!.start();
      if (!_valid) throw StateError('Native audio output unavailable');
      _opened = true;
      _opening = false;
      _publishMetadata();
    } catch (_) {
      await close();
      rethrow;
    }
  }

  static Uint8List wavHeader(int rate, int channels) => XitaAudioRenderer.wavHeader(rate, channels);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _stateFeed?.close();
    _stateFeed = null;
    _heartbeat?.cancel();
    _udp?.close();
    _udp = null;
    if (!_meshReady.isCompleted) _meshReady.completeError(StateError('Native audio ended'));
    if (!_descriptorReady.isCompleted) _descriptorReady.completeError(StateError('Native audio ended'));
    final mesh = _mesh;
    _mesh = null;
    // A private peer has its own group state; remove only our membership.
    // Closing the point-to-point link also retires native sending to this node.
    unawaited(mesh?.close());
    try {
      final renderer = _renderer;
      if (renderer != null) {
        await renderer.close();
      } else {
        await output.closeCalderaAudio(_owner);
      }
    } finally {
      onClosed?.call();
    }
  }
}
