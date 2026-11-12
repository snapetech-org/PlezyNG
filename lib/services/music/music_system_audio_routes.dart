import 'package:flutter/services.dart';

class MusicSystemAudioOutput {
  const MusicSystemAudioOutput({
    required this.id,
    required this.name,
    required this.type,
    required this.bluetooth,
    required this.channels,
  });
  final String id, name, type;
  final bool bluetooth;
  final int channels;
}

/// The OS's selected audio session route, not a list of available devices or
/// a claim about hardware clock synchronization / bit-perfect rendering.
class MusicSystemAudioRoute {
  MusicSystemAudioRoute({
    required Iterable<MusicSystemAudioOutput> outputs,
    required this.sampleRate,
    required this.outputChannels,
    required this.outputLatencyMs,
    required this.ioBufferMs,
  }) : outputs = List.unmodifiable(outputs);
  final List<MusicSystemAudioOutput> outputs;
  final double sampleRate, outputLatencyMs, ioBufferMs;
  final int outputChannels;

  factory MusicSystemAudioRoute.fromMessage(Object? message) {
    if (message is! Map || message['version'] != 1) throw const FormatException('Unsupported system audio route');
    double number(Map value, String key, double maximum) {
      final raw = value[key];
      if (raw is! num || !raw.isFinite || raw < 0 || raw > maximum) {
        throw const FormatException('Invalid system route measurement');
      }
      return raw.toDouble();
    }

    int channels(Map value, String key) {
      final raw = value[key];
      if (raw is! int || raw < 0 || raw > 32) throw const FormatException('Invalid system route channels');
      return raw;
    }

    String text(Map value, String key, int length, {bool empty = false}) {
      final raw = value[key];
      if (raw is! String || (!empty && raw.isEmpty) || raw.length > length || raw.contains('\u0000')) {
        throw const FormatException('Invalid system route identity');
      }
      return raw;
    }

    final rows = message['outputs'];
    if (rows is! List || rows.length > 16) throw const FormatException('Invalid system outputs');
    final outputs = <MusicSystemAudioOutput>[];
    final ids = <String>{};
    for (final row in rows) {
      if (row is! Map || row['bluetooth'] is! bool) throw const FormatException('Invalid system output');
      final id = text(row, 'id', 512);
      if (!ids.add(id)) throw const FormatException('Duplicate system output');
      outputs.add(
        MusicSystemAudioOutput(
          id: id,
          name: text(row, 'name', 256, empty: true),
          type: text(row, 'type', 128),
          bluetooth: row['bluetooth'] as bool,
          channels: channels(row, 'channels'),
        ),
      );
    }
    return MusicSystemAudioRoute(
      outputs: outputs,
      sampleRate: number(message, 'sampleRate', 768000),
      outputChannels: channels(message, 'outputChannels'),
      outputLatencyMs: number(message, 'outputLatencyMs', 60000),
      ioBufferMs: number(message, 'ioBufferMs', 60000),
    );
  }
}

/// Read-only native route boundary. It never sends a device ID or server
/// credentials to another endpoint and does not configure the audio session.
class MusicSystemAudioRoutes {
  static const _methods = MethodChannel('com.pleazyng/music_audio_route');
  static const _events = EventChannel('com.pleazyng/music_audio_route/events');
  static Stream<MusicSystemAudioRoute>? _changes;

  static Future<MusicSystemAudioRoute?> read() async {
    try {
      final message = await _methods.invokeMethod<Object?>('snapshot');
      return message == null ? null : MusicSystemAudioRoute.fromMessage(message);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Stream<MusicSystemAudioRoute> get changes =>
      _changes ??= _events.receiveBroadcastStream().map(MusicSystemAudioRoute.fromMessage);
}
