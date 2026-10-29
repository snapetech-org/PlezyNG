import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// A single persistent native decoder on its own isolate. Only one bounded
/// request can be outstanding; playback owns buffering, clocks and admission.
final class SubtitleOnlineRecognizer {
  SubtitleOnlineRecognizer._();
  static bool get supported => const bool.fromEnvironment('dart.library.io') &&
      !const bool.fromEnvironment('PLEZY_TIZEN') && !const bool.fromEnvironment('PLEZY_WEBOS') &&
      !const bool.fromEnvironment('TVOS_BUILD') &&
      (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows || Platform.isLinux);
  final ReceivePort _messages = ReceivePort();
  final Completer<void> _ready = Completer<void>();
  Completer<Map<String, Object?>>? _pending;
  SendPort? _commands;
  bool _closing = false, _closed = false;
  String language = 'und';
  String modelDigest = '';

  static Future<SubtitleOnlineRecognizer> open(String manifest) async {
    if (!supported) throw UnsupportedError('This platform does not package the Sherpa streaming runtime.');
    final owner = SubtitleOnlineRecognizer._();
    owner._messages.listen(owner._receive);
    try {
      await Isolate.spawn(_onlineWorker, (owner._messages.sendPort, manifest),
        onError: owner._messages.sendPort, onExit: owner._messages.sendPort, errorsAreFatal: true);
      await owner._ready.future;
      return owner;
    } catch (_) { owner._messages.close(); rethrow; }
  }
  void _receive(Object? message) {
    if (message is Map && message['ready'] is SendPort) {
      _commands = message['ready'] as SendPort;
      language = message['language'] as String;
      modelDigest = message['digest'] as String;
      _ready.complete();
    } else if (message is Map && message['error'] == null) {
      final pending = _pending; _pending = null;
      pending?.complete(Map<String, Object?>.from(message));
    } else {
      final error = StateError(message is Map ? message['error'].toString() : 'The local streaming recognizer exited.');
      _closed = true;
      if (!_ready.isCompleted) _ready.completeError(error);
      final pending = _pending; _pending = null;
      if (pending != null) {
        if (_closing && message == null) { pending.complete(const {}); } else { pending.completeError(error); }
      }
      _messages.close();
    }
  }
  Future<Map<String, Object?>> accept(Float32List samples, {required bool reset, required bool finish}) {
    if (samples.length > 16000 || samples.any((sample) => !sample.isFinite || sample.abs() > 1)) {
      throw ArgumentError('Streaming recognition accepts at most one second of normalized 16 kHz mono PCM.');
    }
    return _request({'samples': TransferableTypedData.fromList([samples.buffer.asUint8List(samples.offsetInBytes, samples.lengthInBytes)]),
      'reset': reset, 'finish': finish});
  }
  Future<Map<String, Object?>> _request(Map<String, Object?> request) {
    if (_closed || _commands == null || _pending != null) throw StateError('Streaming recognizer unavailable or busy.');
    final pending = Completer<Map<String, Object?>>(); _pending = pending;
    _commands!.send(request);
    return pending.future;
  }
  Future<void> dispose() async {
    if (_closing || _closed) return;
    _closing = true;
    try { await _pending?.future; } catch (_) {}
    if (!_closed) { try { await _request({'close': true}); } finally { _closed = true; _messages.close(); } }
  }
}

Future<void> _onlineWorker((SendPort, String) arguments) async {
  final (output, manifestPath) = arguments;
  final input = ReceivePort();
  sherpa.OnlineRecognizer? recognizer;
  sherpa.OnlineStream? stream;
  try {
    final manifest = File(manifestPath);
    if (!p.isAbsolute(manifestPath) || await FileSystemEntity.type(manifestPath, followLinks: false) != FileSystemEntityType.file ||
        await manifest.length() > 16384) throw const FormatException('Choose a bounded local streaming-model manifest.');
    final manifestBytes = BytesBuilder(copy: false);
    await for (final chunk in manifest.openRead(0, 16385)) { manifestBytes.add(chunk); }
    final bytes = manifestBytes.takeBytes();
    if (bytes.length > 16384) throw const FormatException('Streaming manifest exceeds its byte bound.');
    final config = jsonDecode(utf8.decode(bytes));
    if (config is! Map || config['schema'] != 1 || config['type'] != 'zipformer2-transducer' ||
        config['sampleRate'] != 16000 || config['language'] is! String ||
        !RegExp(r'^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$').hasMatch(config['language']) || config['files'] is! Map) {
      throw const FormatException('Expected a 16 kHz Zipformer2 streaming manifest with language and hashed encoder, decoder, joiner and tokens files.');
    }
    final paths = <String, String>{};
    var total = 0;
    for (final key in ['encoder', 'decoder', 'joiner', 'tokens']) {
      final row = config['files'][key];
      if (row is! Map || row['name'] is! String || !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,159}$').hasMatch(row['name']) ||
          row['sha256'] is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(row['sha256'])) throw const FormatException('Invalid local streaming-model member.');
      final path = p.join(manifest.parent.path, row['name'] as String);
      if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.file) throw const FormatException('Streaming model members must be regular local files.');
      final file = File(path), before = await File(path).stat();
      total += before.size;
      if (before.size <= 0 || total > 1024 * 1024 * 1024 || key == 'tokens' && before.size > 16 * 1024 * 1024) {
        throw const FormatException('Streaming model exceeds the 1 GiB total / 16 MiB tokens limit.');
      }
      final digest = (await sha256.bind(file.openRead(0, before.size)).first).toString();
      final after = await file.stat();
      if (digest != row['sha256'] || before.size != after.size || before.modified != after.modified) {
        throw const FormatException('Streaming model integrity check failed.');
      }
      paths[key] = path;
    }
    await sherpa.initBindingsAsync();
    final engine = recognizer = sherpa.OnlineRecognizer(sherpa.OnlineRecognizerConfig(
      model: sherpa.OnlineModelConfig(transducer: sherpa.OnlineTransducerModelConfig(
        encoder: paths['encoder']!, decoder: paths['decoder']!, joiner: paths['joiner']!),
        tokens: paths['tokens']!, modelType: 'zipformer2', provider: 'cpu', numThreads: 2, debug: false),
      enableEndpoint: true, rule1MinTrailingSilence: 2.4, rule2MinTrailingSilence: 1.2, rule3MinUtteranceLength: 12));
    var consumed = 0, utteranceStart = 0, streamStart = 0;
    void replaceStream() { stream?.free(); stream = null; stream = engine.createStream(); streamStart = consumed; }
    replaceStream();
    output.send({'ready': input.sendPort, 'language': config['language'], 'digest': sha256.convert(bytes).toString()});
    await for (final command in input) {
      if (command is! Map) throw const FormatException('Invalid streaming command');
      if (command['close'] == true) break;
      if (command['reset'] == true) { consumed = 0; utteranceStart = 0; replaceStream(); }
      final samples = (command['samples'] as TransferableTypedData).materialize().asFloat32List();
      if (samples.length > 16000) throw const FormatException('Streaming input exceeds its bound');
      final finals = <Map<String, Object?>>[];
      final watch = Stopwatch()..start();
      void decode() {
        var steps = 0;
        while (engine.isReady(stream!)) {
          if (++steps > 256 || watch.elapsedMilliseconds > 30000) throw StateError('Streaming inference exceeded its step/time budget.');
          engine.decode(stream!);
        }
      }
      String text() {
        final value = engine.getResult(stream!).text.trim().replaceAll(RegExp(r'\s+'), ' ');
        if (value.length > 1200) throw const FormatException('Streaming hypothesis exceeded its text bound');
        return value;
      }
      void finalize() {
        final value = text();
        if (value.isNotEmpty && consumed > utteranceStart) finals.add({'text': value,
          'startMs': (utteranceStart * 1000 / 16000).round(), 'endMs': (consumed * 1000 / 16000).round()});
        utteranceStart = consumed;
      }
      for (var at = 0; at < samples.length; at += 1600) {
        final end = math.min(at + 1600, samples.length);
        stream!.acceptWaveform(samples: Float32List.sublistView(samples, at, end), sampleRate: 16000);
        consumed += end - at;
        decode();
        if (engine.isEndpoint(stream!)) { finalize(); engine.reset(stream!); }
      }
      if (command['finish'] == true) {
        // Decoder context only: padding never advances the source clock.
        stream!.acceptWaveform(samples: Float32List(12800), sampleRate: 16000);
        stream!.inputFinished(); decode(); finalize(); replaceStream();
      } else if (consumed - streamStart >= 16000 * 60) {
        // Bound native feature/context retention, including prolonged silence.
        stream!.inputFinished(); decode(); finalize(); replaceStream();
      }
      output.send({'cues': finals, 'partial': text(), 'startMs': (utteranceStart * 1000 / 16000).round(),
        'endMs': (consumed * 1000 / 16000).round(), 'pending': consumed > utteranceStart});
    }
  } catch (error) { output.send({'error': 'Streaming recognition stopped: $error'}); }
  finally { try { stream?.free(); } finally { recognizer?.free(); input.close(); } }
}
