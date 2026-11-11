import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'caldera_group.dart';
import 'xita_packet.dart';

/// The shared music session retains audio focus, OS controls and teardown.
abstract interface class CalderaAudioOutput {
  Future<bool> openCalderaAudio(Object owner, Uri source, String title, bool Function() current);
  bool ownsCalderaAudio(Object owner);
  Future<void> closeCalderaAudio(Object owner);
}

abstract interface class NativeMusicGroupControls {
  bool get receivingNativeMusicGroup;
  Future<void> receiveNativeMusicGroup(CalderaNode leader, {required bool Function() current});
  Future<void> leaveNativeMusicGroup();
}

/// A bounded reorder window. Rendering advances the source clock even when a
/// packet is missing, replacing only the missing frames with silence.
class XitaJitterBuffer {
  XitaJitterBuffer(this.descriptor) : clock = XitaClock(descriptor.sampleRate);
  final XitaDescriptor descriptor;
  final XitaClock clock;
  final _packets = SplayTreeMap<int, XitaAudio>();
  int? _cursor;
  int _queuedFrames = 0;
  int missingFrames = 0;
  int droppedPackets = 0;

  bool add(XitaAudio packet, int arrivalMicros) {
    if (packet.format != descriptor.format ||
        packet.channels != descriptor.channels ||
        packet.terminated ||
        packet.suspended) {
      return false;
    }
    final frame = clock.unwrap(packet.frame);
    if (_cursor != null && (frame + packet.frames <= _cursor! || frame - _cursor! > descriptor.sampleRate ~/ 2)) {
      droppedPackets++;
      return false;
    }
    if (_packets.containsKey(frame) ||
        _packets.length >= 1024 ||
        _queuedFrames + packet.frames > descriptor.sampleRate ~/ 2) {
      droppedPackets++;
      return false;
    }
    // Reject overlap, including a replay with a different starting counter.
    final before = _packets.lastKeyBefore(frame + 1);
    final after = _packets.firstKeyAfter(frame - 1);
    if (before != null && before + _packets[before]!.frames > frame || after != null && after < frame + packet.frames) {
      droppedPackets++;
      return false;
    }
    clock.observe(packet, arrivalMicros);
    if (!clock.ready) return false;
    _cursor ??= frame;
    _packets[frame] = packet;
    _queuedFrames += packet.frames;
    return true;
  }

  /// Float32 little-endian WAV payload, at most one output tick.
  Uint8List render(int nowMicros, {int maximumFrames = 4096}) {
    if (_cursor == null || !clock.ready) return Uint8List(0);
    final available = ((nowMicros - clock.presentationMicros(_cursor!)) * descriptor.sampleRate / 1000000).floor();
    final frames = available.clamp(0, maximumFrames);
    if (frames == 0) return Uint8List(0);
    final bytes = ByteData(frames * descriptor.channels * 4);
    for (var index = 0; index < frames; index++) {
      final frame = _cursor! + index;
      final key = _packets.lastKeyBefore(frame + 1);
      final packet = key == null ? null : _packets[key];
      if (packet == null || frame >= key! + packet.frames || packet.skipped) {
        missingFrames++;
        continue;
      }
      for (var channel = 0; channel < descriptor.channels; channel++) {
        bytes.setFloat32(
          (index * descriptor.channels + channel) * 4,
          packet.samples[(frame - key) * descriptor.channels + channel],
          Endian.little,
        );
      }
    }
    _cursor = _cursor! + frames;
    final expired = _packets.keys.where((key) => key + _packets[key]!.frames <= _cursor!).toList();
    for (final key in expired) {
      _queuedFrames -= _packets.remove(key)!.frames;
    }
    return bytes.buffer.asUint8List();
  }
}

/// An explicitly selected native peer is the sole allowed UDP and mesh source.
/// No Plex credentials, raw library data or write authority cross this channel.
class CalderaAudioSink {
  CalderaAudioSink({required this.leader, required this.output, required this.current});
  final CalderaNode leader;
  final CalderaAudioOutput output;
  final bool Function() current;
  final id = const Uuid().v4();
  final _owner = Object();
  final _clock = Stopwatch()..start();
  RawDatagramSocket? _udp;
  WebSocket? _mesh;
  HttpServer? _http;
  HttpResponse? _response;
  Timer? _pump, _heartbeat;
  XitaJitterBuffer? _audio;
  final _descriptorReady = Completer<XitaDescriptor>();
  final _meshReady = Completer<void>();
  bool _closed = false, _opened = false, _opening = false;
  int? _sourcePort;
  int _lastAudio = 0, _lastMesh = 0;
  bool _writing = false;
  int _lastFlush = 0;
  bool get active => !_closed && _opened && output.ownsCalderaAudio(_owner);
  bool get _valid => !_closed && current() && (!_opened || output.ownsCalderaAudio(_owner));

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
            if (decoded.terminated || decoded.suspended) {
              unawaited(close());
              return;
            }
            if (_audio != null &&
                (decoded.sampleRate != _audio!.descriptor.sampleRate ||
                    decoded.channels != _audio!.descriptor.channels ||
                    decoded.format != _audio!.descriptor.format)) {
              unawaited(close());
              return;
            }
            _sourcePort ??= packet.port;
            _audio ??= XitaJitterBuffer(decoded);
            if (!_descriptorReady.isCompleted) _descriptorReady.complete(decoded);
          } else if (decoded is XitaAudio && _audio != null) {
            if (decoded.terminated || decoded.suspended) {
              unawaited(close());
              return;
            }
            if (_audio!.add(decoded, _clock.elapsedMicroseconds)) _lastAudio = _clock.elapsedMilliseconds;
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
              if (const ['Hello', 'SetState', 'SetNodeState'].contains(message['method'])) {
                if (data is! Map || data['version'] != '1.0.0') throw const FormatException('Unsupported native peer');
                if (!_meshReady.isCompleted) _meshReady.complete();
              }
              if (const ['SetState', 'SetNodeState'].contains(message['method']) &&
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
      _send('SetSinksForSource', {
        'source': leader.id,
        'sinks': [leader.id, id],
      });
      final descriptor = await _descriptorReady.future.timeout(const Duration(seconds: 5));
      if (!_valid) throw StateError('Native audio scope changed');
      _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final path = '/${const Uuid().v4()}.wav';
      _http!.listen((request) {
        if (!_valid ||
            _response != null ||
            request.method != 'GET' ||
            request.uri.path != path ||
            request.uri.hasQuery) {
          request.response.statusCode = 404;
          unawaited(request.response.close());
          return;
        }
        _response = request.response;
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.headers.set('Cache-Control', 'no-store');
        request.response.bufferOutput = false;
        request.response.add(wavHeader(descriptor.sampleRate, descriptor.channels));
        unawaited(request.response.done.then<void>((_) => close(), onError: (Object _) => close()));
      });
      _pump = Timer.periodic(const Duration(milliseconds: 10), (_) {
        if (!_valid) {
          unawaited(close());
          return;
        }
        final response = _response;
        if (response == null) return;
        if (_writing) {
          if (_clock.elapsedMilliseconds - _lastFlush > 500) unawaited(close());
          return;
        }
        final bytes = _audio?.render(_clock.elapsedMicroseconds);
        if (bytes != null && bytes.isNotEmpty) {
          _writing = true;
          _lastFlush = _clock.elapsedMilliseconds;
          response.add(bytes);
          unawaited(
            response.flush().then<void>(
              (_) {
                _writing = false;
              },
              onError: (Object _) {
                _writing = false;
                unawaited(close());
              },
            ),
          );
        }
      });
      _heartbeat = Timer.periodic(const Duration(milliseconds: 500), (_) {
        final now = _clock.elapsedMilliseconds;
        if (!_valid || now - _lastAudio > 5000 || now - _lastMesh > 15000) {
          unawaited(close());
          return;
        }
        _mesh?.add('{"data":"ping"}');
      });
      if (!await output.openCalderaAudio(
            _owner,
            Uri.parse('http://127.0.0.1:${_http!.port}$path'),
            leader.name,
            () => _valid,
          ) ||
          !_valid) {
        throw StateError('Native audio output unavailable');
      }
      _opened = true;
      _opening = false;
    } catch (_) {
      await close();
      rethrow;
    }
  }

  static Uint8List wavHeader(int rate, int channels) {
    final data = ByteData(44);
    void ascii(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        data.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 0xffffffff, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 3, Endian.little);
    data.setUint16(22, channels, Endian.little);
    data.setUint32(24, rate, Endian.little);
    data.setUint32(28, rate * channels * 4, Endian.little);
    data.setUint16(32, channels * 4, Endian.little);
    data.setUint16(34, 32, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, 0xffffffff, Endian.little);
    return data.buffer.asUint8List();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pump?.cancel();
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
    unawaited(_response?.close());
    _response = null;
    await _http?.close(force: true);
    _http = null;
    await output.closeCalderaAudio(_owner);
  }
}
