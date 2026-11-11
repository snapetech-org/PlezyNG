import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';

/// The native Snapjack controller contract observed with Caldera 1.0.44.
/// This controls native players; it does not advertise a Pleazyng audio sink.
class CalderaNode {
  const CalderaNode({
    required this.id,
    required this.name,
    required this.address,
    required this.companionPort,
    required this.expires,
    this.meshPort = 1998,
  });
  final String id, name;
  final InternetAddress address;
  final int companionPort, meshPort;
  final DateTime expires;
  String get endpoint => '${address.address}:$companionPort';

  static bool privateAddress(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) return false;
    final bytes = address.rawAddress;
    return bytes[0] == 10 || bytes[0] == 192 && bytes[1] == 168 || bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31;
  }

  static CalderaNode? parse(List<int> bytes, InternetAddress source, {DateTime? now}) {
    if (bytes.length > 4096 || !privateAddress(source)) return null;
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map || value['available'] != true) return null;
      final data = value['data'], name = value['name'], interval = value['interval'];
      if (data is! Map ||
          data['proto'] != 'tcp' ||
          name is! String ||
          name.isEmpty ||
          name.length > 128 ||
          interval is! int ||
          interval < 100 ||
          interval > 60000) {
        return null;
      }
      final node = data['node'], port = data['companionPort'], meshPort = data['port'];
      if (node is! Map ||
          node['version'] != 1 ||
          port is! int ||
          port < 1024 ||
          port > 65535 ||
          meshPort is! int ||
          meshPort < 1024 ||
          meshPort > 65535) {
        return null;
      }
      final id = node['uuid'], addresses = node['addresses'];
      if (id is! String ||
          !RegExp(r'^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$').hasMatch(id) ||
          addresses is! List ||
          addresses.length > 8 ||
          !addresses.any((entry) => entry is Map && entry['address'] == source.address)) {
        return null;
      }
      return CalderaNode(
        id: id,
        name: name,
        address: source,
        companionPort: port,
        meshPort: meshPort,
        expires: (now ?? DateTime.now()).add(Duration(milliseconds: (interval * 3).clamp(5000, 15000))),
      );
    } on FormatException {
      return null;
    }
  }
}

class CalderaDiscovery {
  final _changes = StreamController<List<CalderaNode>>.broadcast();
  final _nodes = <String, CalderaNode>{};
  RawDatagramSocket? _socket;
  Timer? _prune;
  bool _disposed = false;
  Stream<List<CalderaNode>> get changes => _changes.stream;
  List<CalderaNode> get nodes => _nodes.values.where((node) => node.expires.isAfter(DateTime.now())).toList();

  Future<void> start() async {
    if (_disposed || _socket != null) return;
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 44201, reuseAddress: true);
    if (_disposed) {
      socket.close();
      return;
    }
    _socket = socket;
    final group = InternetAddress('224.0.0.234');
    var joined = false;
    for (final interface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      try {
        socket.joinMulticast(group, interface);
        joined = true;
      } on SocketException {
        continue;
      }
    }
    if (!joined) {
      socket.close();
      _socket = null;
      throw const SocketException('Native group discovery unavailable');
    }
    socket.listen(
      (event) {
        if (event != RawSocketEvent.read || _disposed) return;
        Datagram? packet;
        while ((packet = socket.receive()) != null) {
          final node = CalderaNode.parse(packet!.data, packet.address);
          if (node == null) continue;
          if (_nodes.length >= 64 && !_nodes.containsKey(node.id)) continue;
          _nodes[node.id] = node;
        }
        _changes.add(nodes);
      },
      onError: (Object error) {
        if (!_disposed) _changes.addError(error);
      },
    );
    _prune = Timer.periodic(const Duration(seconds: 2), (_) {
      _nodes.removeWhere((_, node) => !node.expires.isAfter(DateTime.now()));
      if (!_disposed) _changes.add(nodes);
    });
  }

  void dispose() {
    _disposed = true;
    _prune?.cancel();
    _socket?.close();
    unawaited(_changes.close());
  }
}

typedef CalderaState = ({String player, String title, String state, int volume, int position, int duration});

class CalderaGroupClient {
  CalderaGroupClient({String? clientIdentifier}) : _identifier = clientIdentifier ?? const Uuid().v4();
  final String _identifier;
  int _command = 0;

  static List<Map<String, dynamic>> meshMessages(String frame) {
    if (utf8.encode(frame).length > 64 * 1024) throw const FormatException('Native mesh frame too large');
    final messages = <Map<String, dynamic>>[];
    var depth = 0, start = -1;
    var quoted = false, escaped = false;
    for (var index = 0; index < frame.length; index++) {
      final char = frame[index];
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (char == r'\') {
          escaped = true;
        } else if (char == '"') {
          quoted = false;
        }
        continue;
      }
      if (char == '"') {
        quoted = true;
        continue;
      }
      if (char == '{' || char == '[') {
        if (depth == 0) start = index;
        if (++depth > 24) throw const FormatException('Native mesh nesting too deep');
      } else if (char == '}' || char == ']') {
        if (--depth < 0) throw const FormatException('Invalid native mesh frame');
        if (depth == 0) {
          final value = jsonDecode(frame.substring(start, index + 1));
          if (value is! Map<String, dynamic> || messages.length >= 32) {
            throw const FormatException('Invalid native mesh message');
          }
          messages.add(value);
        }
      } else if (depth == 0 && char.trim().isNotEmpty) {
        throw const FormatException('Invalid native mesh frame');
      }
    }
    if (depth != 0 || quoted) throw const FormatException('Incomplete native mesh message');
    return messages;
  }

  /// Manual access also works on networks/platforms that block multicast.
  /// The mesh announces its UUID; the user does not need to know that ID.
  Future<CalderaNode> inspect(String endpoint, {int meshPort = 1998, required bool Function() current}) async {
    final parsed = Uri.tryParse('http://$endpoint');
    final address = parsed == null ? null : InternetAddress.tryParse(parsed.host);
    final port = parsed?.port ?? 0;
    if (address == null ||
        !CalderaNode.privateAddress(address) ||
        port < 1024 ||
        port > 65535 ||
        parsed!.userInfo.isNotEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment ||
        parsed.path.isNotEmpty ||
        meshPort < 1024 ||
        meshPort > 65535 ||
        !current()) {
      throw ArgumentError('Invalid native endpoint');
    }
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    WebSocket? socket;
    try {
      socket = await WebSocket.connect(
        'ws://${address.address}:$meshPort/',
        customClient: http,
      ).timeout(const Duration(seconds: 5));
      socket.pingInterval = const Duration(seconds: 2);
      final response = socket
          .expand((value) {
            if (value is! String) throw const FormatException('Invalid native mesh frame');
            return meshMessages(value);
          })
          .firstWhere((value) => const ['Hello', 'SetState', 'SetNodeState'].contains(value['method']))
          .timeout(const Duration(seconds: 5));
      socket.add(
        jsonEncode({
          'method': 'Hello',
          'source': const Uuid().v4(),
          'sentAt': DateTime.now().millisecondsSinceEpoch,
          'data': {'capabilities': null, 'version': '1.0.0'},
        }),
      );
      final hello = await response;
      final data = hello['data'];
      if (data is! Map || data['version'] != '1.0.0') {
        throw const FormatException('Unsupported native mesh version');
      }
      final id = hello['source'];
      if (id is! String ||
          !RegExp(r'^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$').hasMatch(id) ||
          !current()) {
        throw const FormatException('Native mesh identity unavailable');
      }
      final node = CalderaNode(
        id: id,
        name: endpoint,
        address: address,
        companionPort: port,
        meshPort: meshPort,
        expires: DateTime.now().add(const Duration(days: 1)),
      );
      await state(node, current: current);
      return node;
    } finally {
      unawaited(socket?.close());
      http.close(force: true);
    }
  }

  Future<T> _request<T>(
    CalderaNode node,
    String path,
    Map<String, String> query,
    Future<T> Function(HttpClientResponse) read, {
    String? target,
    required bool Function() current,
  }) async {
    if (!current() || !CalderaNode.privateAddress(node.address)) throw StateError('Native group source changed');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    HttpClientRequest? request;
    final deadline = Timer(const Duration(seconds: 5), () => client.close(force: true));
    try {
      request = await client.getUrl(
        Uri(scheme: 'http', host: node.address.address, port: node.companionPort, path: path, queryParameters: query),
      );
      if (!current()) throw StateError('Native group source changed');
      request.followRedirects = false;
      request.headers.set('X-Plex-Client-Identifier', _identifier);
      if (target != null) request.headers.set('X-Plex-Target-Client-Identifier', target);
      final response = await request.close();
      if (response.statusCode != 200) throw StateError('Native group request refused');
      final result = await read(response);
      if (!current()) throw StateError('Native group source changed');
      return result;
    } finally {
      deadline.cancel();
      request?.abort();
      client.close(force: true);
    }
  }

  Stream<List<int>> _bounded(HttpClientResponse response) async* {
    var count = 0;
    await for (final chunk in response) {
      count += chunk.length;
      if (count > 64 * 1024) throw const FormatException('Native group response too large');
      yield chunk;
    }
  }

  Future<CalderaState> state(CalderaNode node, {required bool Function() current}) =>
      _request(node, '/:/eventsource/notifications', {}, (response) async {
        if (response.headers.contentType?.mimeType != 'text/event-stream') {
          throw const FormatException('Native group state unavailable');
        }
        var event = '';
        final data = <String>[];
        await for (final line in _bounded(response).transform(utf8.decoder).transform(const LineSplitter())) {
          if (line.startsWith('event:')) event = line.substring(6).trim();
          if (line.startsWith('data:')) data.add(line.substring(5).trimLeft());
          if (line.isNotEmpty) continue;
          if (event == 'state') {
            final value = jsonDecode(data.join('\n'));
            if (value is! Map || value['meshVersion'] != '2.0.0' || value['type'] != 'track') {
              throw const FormatException('Unsupported native group version');
            }
            final player = value['playerIdentifier'], title = value['title'], state = value['state'];
            final volume = value['volume'], position = value['time'], duration = value['duration'];
            if (player is! String ||
                !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(player) ||
                title is! String ||
                title.length > 512 ||
                !const ['stopped', 'buffering', 'playing', 'paused'].contains(state) ||
                volume is! int ||
                volume < 0 ||
                volume > 100 ||
                position is! int ||
                position < 0 ||
                position > 86400000 ||
                duration is! int ||
                duration < 0 ||
                duration > 86400000) {
              throw const FormatException('Invalid native group state');
            }
            return (
              player: player,
              title: title,
              state: state as String,
              volume: volume,
              position: position,
              duration: duration,
            );
          }
          event = '';
          data.clear();
        }
        throw const FormatException('Native group state missing');
      }, current: current);

  Future<void> _control(
    CalderaNode node,
    CalderaState expected,
    String action,
    Map<String, String> parameters, {
    required bool Function() current,
  }) async {
    final latest = await state(node, current: current);
    if (latest.player != expected.player) throw StateError('Native player identity changed');
    await _request(
      node,
      '/player/playback/$action',
      {...parameters, 'commandID': '${++_command}', 'type': 'music'},
      (response) async {
        final text = await _bounded(response).transform(utf8.decoder).join();
        // Current native Companion builds acknowledge accepted commands with
        // an empty HTTP 200 body; older builds return an XML Response.
        if (text.trim().isEmpty) return;
        final reply = XmlDocument.parse(text).rootElement;
        if (reply.name.local != 'Response' || reply.getAttribute('code') != '200') {
          throw StateError('Native group command rejected');
        }
      },
      target: expected.player,
      current: current,
    );
  }

  Future<void> group(
    CalderaNode leader,
    CalderaState expected,
    List<CalderaNode> sinks, {
    required bool Function() current,
  }) async {
    if (sinks.length > 16 ||
        sinks.map((sink) => sink.id).toSet().length != sinks.length ||
        sinks.any((sink) => sink.id == leader.id)) {
      throw ArgumentError('Invalid native group sinks');
    }
    for (final sink in sinks) {
      await state(sink, current: current);
    }
    // The HTTP controller route takes the additional sinks. Native mesh
    // broadcasts include the source itself in the resulting sink set.
    await _control(leader, expected, 'setSinksForSource', {
      'source': leader.id,
      'sinks': sinks.map((sink) => sink.id).join(','),
    }, current: current);
  }

  Future<void> transport(
    CalderaNode node,
    CalderaState expected,
    String action, {
    required bool Function() current,
  }) async {
    if (!const ['play', 'pause', 'stop', 'skipNext', 'skipPrevious'].contains(action)) {
      throw ArgumentError('Unsupported native transport');
    }
    await _control(node, expected, action, {}, current: current);
  }

  Future<void> volume(CalderaNode node, CalderaState expected, int value, {required bool Function() current}) async {
    if (value < 0 || value > 100) throw ArgumentError('Invalid native volume');
    await _control(node, expected, 'setParameters', {'volume': '$value'}, current: current);
  }
}
