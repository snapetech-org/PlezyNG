import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'caldera_group.dart';

/// One bounded EventSource connection to the explicitly selected native source.
/// The per-event bound resets after dispatch; a long session has no byte quota.
class CalderaStateFeed {
  CalderaStateFeed({required this.node, required this.current, required this.changed, required this.failed});
  final CalderaNode node;
  final bool Function() current;
  final void Function(CalderaNowPlaying) changed;
  final void Function() failed;
  final _ready = Completer<void>();
  HttpClient? _client;
  bool _closed = false;
  String? _player;

  Future<void> start() async {
    if (_closed || _client != null || !current() || !CalderaNode.privateAddress(node.address)) {
      throw StateError('Native state feed unavailable');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    _client = client;
    unawaited(_run(client));
    try {
      await _ready.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      close();
      rethrow;
    }
  }

  Future<void> _run(HttpClient client) async {
    try {
      final request = await client.getUrl(
        Uri(scheme: 'http', host: node.address.address, port: node.companionPort, path: '/:/eventsource/notifications'),
      );
      if (_closed || !current()) throw StateError('Native state scope changed');
      request.followRedirects = false;
      request.headers.set('X-Plex-Client-Identifier', 'Pleazyng-native-state');
      final response = await request.close();
      if (response.statusCode != 200 || response.headers.contentType?.mimeType != 'text/event-stream') {
        throw const FormatException('Native state feed refused');
      }
      final line = <int>[], data = <String>[];
      var event = '', eventBytes = 0;
      await for (final chunk in response) {
        if (_closed || !current()) throw StateError('Native state scope changed');
        for (final byte in chunk) {
          if (++eventBytes > 65536 || line.length > 65536) {
            throw const FormatException('Native state event too large');
          }
          if (byte != 10) {
            line.add(byte);
            continue;
          }
          var text = utf8.decode(line);
          line.clear();
          if (text.endsWith('\r')) text = text.substring(0, text.length - 1);
          if (text.isEmpty) {
            if (event == 'state') {
              final state = CalderaNowPlaying.parse(jsonDecode(data.join('\n')));
              _player ??= state.snapshot.player;
              if (state.snapshot.player != _player) throw const FormatException('Native source identity changed');
              if (_closed || !current()) throw StateError('Native state scope changed');
              changed(state);
              if (!_ready.isCompleted) _ready.complete();
            }
            event = '';
            data.clear();
            eventBytes = 0;
          } else if (text.startsWith('event:')) {
            event = text.substring(6).trim();
          } else if (text.startsWith('data:')) {
            data.add(text.substring(5).trimLeft());
          }
        }
      }
      if (!_closed) throw const FormatException('Native state feed ended');
    } catch (error, stack) {
      if (!_ready.isCompleted) _ready.completeError(error, stack);
      if (!_closed) {
        close();
        failed();
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _client?.close(force: true);
    _client = null;
    if (!_ready.isCompleted) _ready.completeError(StateError('Native state feed closed'));
  }
}
