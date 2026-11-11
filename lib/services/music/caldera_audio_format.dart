import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'caldera_group.dart';

/// Native mesh 1.0 reports no channel capabilities. Its Companion preference
/// exposes the configured decoder width; wider PCM must never be guessed.
class CalderaAudioFormat {
  static Future<({int channels, bool negotiated})> read(CalderaNode node, {required bool Function() current}) async {
    if (!current() || !CalderaNode.privateAddress(node.address)) throw StateError('Native format scope changed');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    final deadline = Timer(const Duration(seconds: 3), () => client.close(force: true));
    HttpClientRequest? request;
    try {
      request = await client.getUrl(
        Uri(
          scheme: 'http',
          host: node.address.address,
          port: node.companionPort,
          path: '/api/prefs',
          queryParameters: {'name': 'audio.channels'},
        ),
      );
      if (!current()) throw StateError('Native format scope changed');
      request.followRedirects = false;
      final response = await request.close();
      if (!current()) throw StateError('Native format scope changed');
      // Older peers without this endpoint retain the established stereo contract.
      if (response.statusCode == 404 || response.statusCode == 405) return (channels: 2, negotiated: false);
      if (response.statusCode != 200) throw const FormatException('Native format unavailable');
      final bytes = <int>[];
      await for (final chunk in response) {
        if (!current() || bytes.length + chunk.length > 64) throw const FormatException('Invalid native format');
        bytes.addAll(chunk);
      }
      final value = jsonDecode(utf8.decode(bytes));
      if (!current()) throw StateError('Native format scope changed');
      if (value is! int || !const [0, 2, 6, 8].contains(value)) {
        throw const FormatException('Unsupported native output channels');
      }
      // Auto uses the native stereo baseline; never infer width from a track.
      return (channels: value == 0 ? 2 : value, negotiated: true);
    } finally {
      deadline.cancel();
      request?.abort();
      client.close(force: true);
    }
  }
}
