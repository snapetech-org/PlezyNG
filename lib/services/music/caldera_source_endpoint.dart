import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:xml/xml.dart';
import 'caldera_group.dart';

class CalderaSourceMetadata {
  const CalderaSourceMetadata({
    required this.title,
    required this.artist,
    required this.album,
    required this.state,
    required this.position,
    required this.duration,
    required this.volume,
  });
  final String title, artist, album, state;
  final Duration position, duration;
  final double volume;
  Map<String, Object> snapshot(String player) => {
    'meshVersion': '2.0.0',
    'playerIdentifier': player,
    'type': 'track',
    'title': title.substring(0, title.length.clamp(0, 512)),
    'artist': artist.substring(0, artist.length.clamp(0, 512)),
    'album': album.substring(0, album.length.clamp(0, 512)),
    'grandparentTitle': artist.substring(0, artist.length.clamp(0, 512)),
    'parentTitle': album.substring(0, album.length.clamp(0, 512)),
    'state': const ['playing', 'paused', 'buffering', 'stopped'].contains(state) ? state : 'stopped',
    'time': position.inMilliseconds.clamp(0, 86400000),
    'duration': duration.inMilliseconds.clamp(0, 86400000),
    'volume': volume.isFinite ? volume.round().clamp(0, 100) : 0,
  };
}

/// Native peers fetch their source's state on Companion port 32500. This host
/// serves selected peers, or the active native availability lease, and never exposes stream URLs,
/// credentials, media-server identifiers or arbitrary queue-loading routes.
class CalderaSourceEndpoint {
  CalderaSourceEndpoint({
    required this.id,
    required Set<String> peers,
    required this.metadata,
    required this.control,
    required this.current,
    this.port = 32500,
    this.allowsPeer,
    this.group,
  }) : peers = Set.unmodifiable(peers);
  final String id;
  final Set<String> peers;
  final CalderaSourceMetadata Function() metadata;
  final Future<void> Function(String action, int? value) control;
  final bool Function() current;
  final int port;
  final bool Function(InternetAddress address)? allowsPeer;
  final Future<void> Function(String source, List<String> sinks)? group;
  bool _allowed(InternetAddress address) => peers.contains(address.address) || allowsPeer?.call(address) == true;
  HttpServer? _server;
  Timer? _timer;
  final _streams = <HttpResponse, _StateStream>{};
  final _receipts = <String, _CommandReceipt>{};
  Future<void> _commands = Future.value();
  int _queued = 0;
  final _clock = Stopwatch()..start();
  bool _closed = false;
  int get boundPort => _server?.port ?? 0;

  Future<void> start() async {
    if (_closed ||
        _server != null ||
        !current() ||
        !RegExp(r'^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$').hasMatch(id)) {
      throw StateError('Native source endpoint unavailable');
    }
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    if (_closed || !current()) {
      await server.close(force: true);
      throw StateError('Native source scope changed');
    }
    _server = server;
    server.listen((request) => unawaited(_request(request)), onError: (Object _) => unawaited(close()));
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _publish());
  }

  Future<void> _reply(HttpResponse response, int status, [String body = '']) async {
    try {
      response.statusCode = status;
      response.headers.contentType = ContentType('text', 'xml');
      if (body.isNotEmpty) response.write(body);
    } on Object {
      /* The peer can disconnect before its reply. */
    }
    try {
      await response.close();
    } on Object {
      /* Already disconnected. */
    }
  }

  Future<void> _request(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Cache-Control', 'no-store');
    response.persistentConnection = false;
    try {
      final remote = request.connectionInfo?.remoteAddress;
      if (_closed || !current() || remote == null || !CalderaNode.privateAddress(remote) || !_allowed(remote)) {
        await _reply(response, 403);
        return;
      }
      if (request.headers.value('Origin') != null ||
          request.method != 'GET' ||
          request.uri.toString().length > 2048 ||
          request.contentLength > 0 ||
          request.headers.chunkedTransferEncoding) {
        await _reply(response, 400);
        return;
      }
      final path = request.uri.path;
      if (path == '/:/eventsource/notifications') {
        if (_streams.length >= 8) {
          await _reply(response, 503);
          return;
        }
        response.headers.contentType = ContentType('text', 'event-stream');
        response.bufferOutput = false;
        final stream = _StateStream(response, remote);
        _streams[response] = stream;
        unawaited(
          response.done.then<void>((_) => _streams.remove(response), onError: (Object _) => _streams.remove(response)),
        );
        _publish();
        return;
      }
      if (path == '/resources') {
        final xml = XmlElement(
          XmlName.parts('MediaContainer'),
          [XmlAttribute(XmlName.parts('size'), '1')],
          [
            XmlElement(XmlName.parts('Player'), [
              XmlAttribute(XmlName.parts('machineIdentifier'), id),
              XmlAttribute(XmlName.parts('title'), 'Pleazyng'),
              XmlAttribute(XmlName.parts('product'), 'Pleazyng'),
              XmlAttribute(XmlName.parts('protocol'), 'plex'),
              XmlAttribute(XmlName.parts('protocolVersion'), '1'),
              XmlAttribute(XmlName.parts('protocolCapabilities'), 'playback,volume'),
            ]),
          ],
        );
        await _reply(response, 200, xml.toXmlString());
        return;
      }
      if (path == '/player/timeline/poll') {
        final state = metadata().snapshot(id);
        final xml = XmlElement(XmlName.parts('MediaContainer'), [], [
          XmlElement(XmlName.parts('Timeline'), [
            for (final entry in {
              'type': 'music',
              'state': state['state'],
              'time': state['time'],
              'duration': state['duration'],
              'volume': state['volume'],
              'machineIdentifier': id,
            }.entries)
              XmlAttribute(XmlName.parts(entry.key), entry.value.toString()),
          ]),
        ]);
        await _reply(response, 200, xml.toXmlString());
        return;
      }
      const prefix = '/player/playback/';
      if (!path.startsWith(prefix)) {
        await _reply(response, 404);
        return;
      }
      if (request.headers.value('X-Plex-Target-Client-Identifier') != id) {
        await _reply(response, 409);
        return;
      }
      final client = request.headers.value('X-Plex-Client-Identifier') ?? '';
      final command = int.tryParse(request.uri.queryParameters['commandID'] ?? '');
      if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(client) ||
          command == null ||
          command < 0 ||
          command > 0x7fffffff ||
          request.uri.queryParameters['type'] != 'music') {
        await _reply(response, 400);
        return;
      }
      final action = path.substring(prefix.length);
      int? value;
      String? groupSource, groupSignature;
      List<String>? groupSinks;
      if (action == 'setSinksForSource' && group != null) {
        final source = request.uri.queryParameters['source'] ?? '';
        final additional = request.uri.queryParameters['sinks'] ?? '';
        final provided = additional.isEmpty ? <String>[] : additional.split(',');
        final sinks = [if (!provided.contains(source)) source, ...provided];
        bool identity(String value) => RegExp(r'^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$').hasMatch(value);
        if (!identity(source) ||
            sinks.length > 9 ||
            sinks.any((value) => !identity(value)) ||
            sinks.toSet().length != sinks.length) {
          await _reply(response, 400);
          return;
        }
        groupSource = source;
        groupSinks = List.unmodifiable(sinks);
        groupSignature = '$source:${(sinks.toList()..sort()).join(',')}';
      } else if (action == 'seekTo') {
        value = int.tryParse(request.uri.queryParameters['offset'] ?? '');
        if (value == null || value < 0 || value > 86400000) {
          await _reply(response, 400);
          return;
        }
      } else if (action == 'setParameters') {
        value = int.tryParse(request.uri.queryParameters['volume'] ?? '');
        if (value == null || value < 0 || value > 100) {
          await _reply(response, 400);
          return;
        }
      } else if (!const ['play', 'pause', 'stop', 'skipNext', 'skipPrevious'].contains(action)) {
        await _reply(response, 404);
        return;
      }
      final prior = _receipts[client];
      if (prior != null && command <= prior.id) {
        if (command != prior.id ||
            prior.action != action ||
            prior.value != value ||
            prior.groupSignature != groupSignature) {
          await _reply(response, 409);
          return;
        }
        final status = await prior.result;
        await _reply(response, status, status == 200 ? '<Response code="200" status="accepted"/>' : '');
        return;
      }
      if (_queued >= 32 || !_receipts.containsKey(client) && _receipts.length >= 32) {
        await _reply(response, 503);
        return;
      }
      final receipt = _CommandReceipt(command, action, value, groupSignature);
      _receipts[client] = receipt;
      _queued++;
      final queued = _commands.then((_) async {
        var status = 200;
        try {
          if (_closed || !current() || !_allowed(remote)) {
            status = 409;
          } else {
            if (groupSource != null) {
              await group!(groupSource, groupSinks!);
            } else {
              await control(action, value);
            }
          }
        } on Object {
          status = 500;
        } finally {
          _queued--;
          receipt.completion.complete(status);
        }
      });
      _commands = queued;
      final status = await receipt.result;
      await _reply(response, status, status == 200 ? '<Response code="200" status="accepted"/>' : '');
    } on Object {
      await _reply(response, 500);
    }
  }

  void _publish() {
    if (_closed) return;
    if (!current()) {
      unawaited(close());
      return;
    }
    late final String event;
    try {
      event = 'event: state\ndata: ${jsonEncode(metadata().snapshot(id))}\n\n';
    } on Object {
      unawaited(close());
      return;
    }
    final now = _clock.elapsedMilliseconds;
    for (final stream in _streams.values.toList()) {
      if (!_allowed(stream.address)) {
        _streams.remove(stream.response);
        unawaited(stream.response.close());
        continue;
      }
      if (stream.writing) {
        if (now - stream.started > 500) {
          _streams.remove(stream.response);
          unawaited(stream.response.close());
        }
        continue;
      }
      stream.writing = true;
      stream.started = now;
      try {
        stream.response.write(event);
        unawaited(
          stream.response.flush().then<void>(
            (_) {
              stream.writing = false;
            },
            onError: (Object _) {
              _streams.remove(stream.response);
              unawaited(stream.response.close());
            },
          ),
        );
      } on Object {
        _streams.remove(stream.response);
        unawaited(stream.response.close());
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    final server = _server;
    _server = null;
    for (final response in _streams.keys.toList()) {
      unawaited(response.close());
    }
    _streams.clear();
    // Existing command replies must finish, including a stop that closes its
    // own source. New requests are refused once this endpoint is retired.
    await server?.close();
  }
}

class _StateStream {
  _StateStream(this.response, this.address);
  final InternetAddress address;
  final HttpResponse response;
  bool writing = false;
  int started = 0;
}

class _CommandReceipt {
  _CommandReceipt(this.id, this.action, this.value, this.groupSignature);
  final String? groupSignature;
  final int id;
  final String action;
  final int? value;
  final completion = Completer<int>();
  Future<int> get result => completion.future;
}
