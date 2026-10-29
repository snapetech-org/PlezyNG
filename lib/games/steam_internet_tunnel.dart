import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../services/companion_remote/remote_auth_context.dart';
import '../services/plezy_server.dart';
import '../utils/web_socket_connect.dart';
import 'game_models.dart';
import 'steam_discovery_codec.dart';
import 'steam_tunnel_codec.dart';

const steamRelayBaseUrl = String.fromEnvironment('PLEZY_STEAM_RELAY_URL');

enum SteamInternetPath { relay, direct }

bool steamPublicIPv4(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4) return false;
  final b = address.rawAddress, a = address.rawAddress[0];
  return a != 0 &&
      a != 10 &&
      a != 127 &&
      a < 224 &&
      !(a == 100 && b[1] >= 64 && b[1] <= 127) &&
      !(a == 169 && b[1] == 254) &&
      !(a == 172 && b[1] >= 16 && b[1] <= 31) &&
      !(a == 192 && (b[1] == 168 || b[1] == 0)) &&
      !(a == 198 && (b[1] == 18 || b[1] == 19 || (b[1] == 51 && b[2] == 100))) &&
      !(a == 203 && b[1] == 0 && b[2] == 113);
}

Uri? steamRelayUri([String value = steamRelayBaseUrl]) {
  final uri = Uri.tryParse(value);
  final catalog = Uri.tryParse(plezyServerBaseUrl);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  if (catalog == null || catalog.scheme != 'https' || catalog.host.isEmpty || uri.origin != catalog.origin) return null;
  return uri.replace(scheme: 'wss', path: '${uri.path.replaceFirst(RegExp(r'/$'), '')}/games/steam/relay');
}

/// A transient route, owned by one retained receiver session (or one host
/// listener). Only Steam's six local UDP ports are ever forwarded. Steam's own
/// PIN/session encryption remains intact inside the paired encrypted channel.
class SteamInternetTunnel {
  SteamInternetTunnel._(this._context, this.host, this._uri, this._allowed, this._admission, this._isPublic);
  final String _admission;
  final bool Function(InternetAddress) _isPublic;
  final RemoteAuthContext _context;
  final bool host;
  final Uri _uri;
  final bool Function() _allowed;
  final path = ValueNotifier(SteamInternetPath.relay);
  final _ready = Completer<void>(), _done = Completer<void>();
  Future<void> get done => _done.future;
  final _local = <RawDatagramSocket>[];
  final _nativePorts = List<int?>.filled(6, null);
  final _subscriptions = <StreamSubscription<dynamic>>[];
  RawDatagramSocket? _udp;
  WebSocket? _socket;
  WebSocketConnectAttempt? _attempt;
  SteamTunnelCodec? _codec;
  Timer? _tick, _batchTimer, _handshakeDeadline;
  InternetAddress? _observer, _candidate;
  int _observerPort = 0, _candidatePort = 0;
  List<int>? _cookie, _observed;
  int _relayBytesPerSecond = 8 * 1024 * 1024;

  /// Reserve 25% for transport overhead and bursts, including a later fallback
  /// from the direct route. Older relays retain the conservative 8 MiB/s cap.
  int get relayBitrateCeilingKbps => _relayBytesPerSecond * 6 ~/ 1000;
  final _incoming = Queue<({Uint8List data, bool udp})>();
  final _outgoing = Queue<({int kind, List<int> data, bool udp})>();
  final _batch = BytesBuilder(copy: false);
  bool _closed = false, _processing = false, _sending = false, _serverReady = false, _peer = false;
  DateTime _directUntil = DateTime.fromMillisecondsSinceEpoch(0), _lastObserve = DateTime.fromMillisecondsSinceEpoch(0);
  List<int>? _ping;
  DateTime? _pingAt;
  int _ticks = 0, _batchCount = 0;

  List<int> get ports => List.unmodifiable(_local.map((s) => s.port));
  bool get current => !_closed && _allowed();
  static Future<SteamInternetTunnel> connect(
    RemoteAuthContext context, {
    required bool host,
    required bool Function() allowed,
    required String admission,
    bool waitForPeer = true,
  }) => _connect(
    context,
    host: host,
    allowed: allowed,
    admission: admission,
    relay: steamRelayUri(),
    waitForPeer: waitForPeer,
    isPublic: steamPublicIPv4,
  );

  @visibleForTesting
  static Future<SteamInternetTunnel> connectForTesting(
    RemoteAuthContext context, {
    required bool host,
    required bool Function() allowed,
    required String admission,
    required Uri relay,
    required bool Function(InternetAddress) isPublic,
    bool waitForPeer = true,
  }) => _connect(
    context,
    host: host,
    allowed: allowed,
    admission: admission,
    relay: relay,
    waitForPeer: waitForPeer,
    isPublic: isPublic,
  );

  static Future<SteamInternetTunnel> _connect(
    RemoteAuthContext context, {
    required bool host,
    required bool Function() allowed,
    required String admission,
    required Uri? relay,
    required bool waitForPeer,
    required bool Function(InternetAddress) isPublic,
  }) async {
    final uri = relay ?? steamRelayUri();
    if (uri == null || uri.scheme != 'wss' || !allowed()) throw const SocketException('Steam internet unavailable');
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(admission)) throw const FormatException('Link Steam');
    final tunnel = SteamInternetTunnel._(context, host, uri, allowed, admission, isPublic);
    // Observe rejection even for a host waiting asynchronously for a remote.
    unawaited(tunnel._ready.future.catchError((Object _) {}));
    try {
      await tunnel._start();
      if (waitForPeer) await tunnel._ready.future.timeout(const Duration(seconds: 15));
      if (!tunnel.current) throw const SocketException('Steam internet retired');
      return tunnel;
    } catch (_) {
      tunnel.close();
      tunnel.path.dispose();
      rethrow;
    }
  }

  Future<void> _start() async {
    _codec = await SteamTunnelCodec.create(_context, host: host);
    if (!current) throw const SocketException('Retired');
    for (var i = 0; i < 6; i++) {
      final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      if (!current) {
        socket.close();
        throw const SocketException('Retired');
      }
      _local.add(socket);
      final index = i;
      _subscriptions.add(
        socket.listen((event) {
          if (event != RawSocketEvent.read) return;
          for (var n = 0; n < 64; n++) {
            final packet = socket.receive();
            if (packet == null) break;
            if (!current ||
                !_ready.isCompleted ||
                packet.address.address != '127.0.0.1' ||
                packet.data.isEmpty ||
                packet.data.length > 2048) {
              continue;
            }
            if (host) {
              if (packet.port != 27031 + index) continue;
            } else {
              _nativePorts[index] = packet.port;
            }
            _datagram(index, packet.data);
          }
        }, onError: (Object _) => close()),
      );
    }
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      if (!current) throw const SocketException('Retired');
      _subscriptions.add(
        _udp!.listen(
          (event) {
            if (event != RawSocketEvent.read) return;
            for (var n = 0; n < 64; n++) {
              final packet = _udp?.receive();
              if (packet == null) break;
              if (packet.address.address == _candidate?.address && packet.port == _candidatePort) {
                _receive(packet.data, udp: true);
              }
            }
          },
          onError: (Object _) {
            _udp?.close();
            _udp = null;
          },
        ),
      );
      unawaited(
        InternetAddress.lookup(_uri.host, type: InternetAddressType.IPv4)
            .timeout(const Duration(seconds: 5))
            .then((values) {
              if (current) _observer = values.where(_isPublic).firstOrNull;
            })
            .catchError((Object _) {}),
      );
    } catch (_) {
      _udp?.close();
      _udp = null;
    }
    if (!current) throw const SocketException('Retired');
    _attempt = WebSocketConnectAttempt(
      _uri,
      connectTimeout: const Duration(seconds: 8),
      headers: {
        'Authorization': 'Bearer ${SteamTunnelCodec.roomToken(_context)}',
        'X-Steam-Relay-Admission': _admission,
        'X-Steam-Relay-Role': host ? 'host' : 'receiver',
        'X-Steam-Relay-Version': '1',
      },
    );
    final socket = await _attempt!.socket;
    if (!current) {
      unawaited(socket.close());
      throw const SocketException('Retired');
    }
    _socket = socket;
    _subscriptions.add(
      socket.listen(
        (message) {
          if (!current) {
            close();
            return;
          }
          if (message is String) {
            _control(message);
          } else if (message is List<int>) {
            _receive(Uint8List.fromList(message), udp: false);
          } else {
            close();
          }
        },
        onError: (Object _) => close(),
        onDone: close,
      ),
    );
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) => _maintain());
  }

  void _control(String message) {
    if (message.length > 512) {
      close();
      return;
    }
    try {
      final m = jsonDecode(message) as Map<String, dynamic>;
      switch (m['kind']) {
        case 'ready':
          if (_serverReady ||
              m['udpPort'] is! int ||
              (m['udpPort'] as int) < 0 ||
              (m['udpPort'] as int) > 65535 ||
              m['udpCookie'] is! String) {
            throw const FormatException();
          }
          final rate = m['bytesPerSecond'] ?? 8 * 1024 * 1024;
          if (rate is! int || rate < 1024 * 1024 || rate > 64 * 1024 * 1024) throw const FormatException();
          _relayBytesPerSecond = rate;
          final cookie = base64Url.decode(base64Url.normalize(m['udpCookie']));
          if (cookie.length != 32) throw const FormatException();
          _cookie = cookie;
          _observerPort = m['udpPort'];
          _serverReady = true;
        case 'peer':
          if (!_serverReady || _peer) throw const FormatException();
          _peer = true;
          _handshakeDeadline = Timer(const Duration(seconds: 10), close);
          _queue(-1, _codec!.hello);
        case 'observed':
          final ip = m['ip'] is String ? InternetAddress.tryParse(m['ip']) : null;
          final port = m['port'];
          if (!_serverReady ||
              ip == null ||
              !_isPublic(ip) ||
              port is! int ||
              port < 1 ||
              port > 65535 ||
              DateTime.now().difference(_lastObserve) < const Duration(seconds: 4)) {
            throw const FormatException();
          }
          _lastObserve = DateTime.now();
          _observed = [...ip.rawAddress, port >> 8, port & 255];
          if (_ready.isCompleted) _queue(2, _observed!);
        default:
          throw const FormatException();
      }
    } catch (_) {
      close();
    }
  }

  void _receive(Uint8List bytes, {required bool udp}) {
    if (!current || bytes.length > 65026 || bytes.isEmpty) return;
    if (_incoming.length >= 32) {
      if (!udp) close();
      return;
    }
    _incoming.add((data: bytes, udp: udp));
    if (!_processing) unawaited(_process());
  }

  Future<void> _process() async {
    _processing = true;
    try {
      while (current && _incoming.isNotEmpty) {
        final entry = _incoming.removeFirst();
        final codec = _codec!;
        if (entry.data[0] == 0x10) {
          if (entry.udp || !_peer) throw const FormatException();
          await codec.acceptHello(entry.data);
          _queue(0, const []);
          continue;
        }
        final packet = await codec.open(entry.data);
        if (!current || packet == null) continue;
        if (packet.kind == 0) {
          if (packet.payload.isNotEmpty || entry.udp) throw const FormatException();
          if (!_ready.isCompleted) {
            _handshakeDeadline?.cancel();
            _ready.complete();
            if (_observed != null) _queue(2, _observed!);
          }
          continue;
        }
        if (!_ready.isCompleted) throw const FormatException();
        switch (packet.kind) {
          case 1:
            _deliver(packet.payload);
          case 2:
            if (entry.udp || packet.payload.length != 6) throw const FormatException();
            final ip = InternetAddress.fromRawAddress(packet.payload.sublist(0, 4));
            final port = (packet.payload[4] << 8) | packet.payload[5];
            if (!_isPublic(ip) || port == 0) throw const FormatException();
            _candidate = ip;
            _candidatePort = port;
            _directUntil = DateTime.fromMillisecondsSinceEpoch(0);
          case 3:
            if (entry.udp && packet.payload.length == 8) _queue(4, packet.payload, udp: true);
          case 4:
            if (entry.udp &&
                packet.payload.length == 8 &&
                listEquals(_ping, packet.payload) &&
                _pingAt != null &&
                DateTime.now().difference(_pingAt!) < const Duration(milliseconds: 1500)) {
              // Keep a brief direct-path lease so a lost NAT mapping does not
              // strand Steam packets while its own transport waits for ACKs.
              _directUntil = DateTime.now().add(const Duration(milliseconds: 2500));
              _ping = null;
            }
        }
      }
    } catch (_) {
      close();
    } finally {
      _processing = false;
    }
  }

  void _deliver(Uint8List bytes) {
    var offset = 0, count = 0;
    // Validate the entire batch before forwarding any of it.
    final rows = <({int port, Uint8List data})>[];
    while (offset < bytes.length) {
      if (offset + 3 > bytes.length || ++count > 128) throw const FormatException();
      final index = bytes[offset], size = (bytes[offset + 1] << 8) | bytes[offset + 2];
      offset += 3;
      if (index >= 6 || size < 1 || size > 2048 || offset + size > bytes.length) throw const FormatException();
      rows.add((port: index, data: Uint8List.sublistView(bytes, offset, offset + size)));
      offset += size;
    }
    for (final row in rows) {
      if (!current) {
        close();
        return;
      }
      final port = host ? 27031 + row.port : _nativePorts[row.port];
      if (port != null) _local[row.port].send(row.data, InternetAddress.loopbackIPv4, port);
    }
  }

  bool get _direct => _udp != null && _candidate != null && DateTime.now().isBefore(_directUntil);
  void _datagram(int index, Uint8List data) {
    final encoded = [index, data.length >> 8, data.length & 255, ...data];
    if (_direct) {
      _queue(1, encoded, udp: true);
      return;
    }
    if (_batch.length + encoded.length > 60000 || _batchCount >= 128) _flush();
    _batch.add(encoded);
    _batchCount++;
    _batchTimer ??= Timer(const Duration(milliseconds: 2), _flush);
  }

  void _flush() {
    _batchTimer?.cancel();
    _batchTimer = null;
    if (_batch.isNotEmpty) _queue(1, _batch.takeBytes());
    _batchCount = 0;
  }

  void _queue(int kind, List<int> data, {bool udp = false}) {
    if (!current) return;
    if (_outgoing.length >= 32) {
      if (kind != 1) close();
      return;
    }
    _outgoing.add((kind: kind, data: data, udp: udp));
    if (!_sending) unawaited(_send());
  }

  Future<void> _send() async {
    _sending = true;
    try {
      while (current && _outgoing.isNotEmpty) {
        final row = _outgoing.removeFirst();
        final packet = row.kind == -1 ? row.data : await _codec!.seal(row.kind, row.data);
        if (!current) break;
        if (row.udp && _udp != null && _candidate != null) {
          _udp!.send(packet, _candidate!, _candidatePort);
        } else {
          await _socket!.addStream(Stream<List<int>>.value(packet)).timeout(const Duration(seconds: 3));
        }
      }
    } catch (_) {
      close();
    } finally {
      _sending = false;
    }
  }

  void _maintain() {
    if (!current) {
      close();
      return;
    }
    _ticks++;
    if ((_ticks <= 4 || _ticks % 20 == 0) &&
        _udp != null &&
        _observer != null &&
        _cookie != null &&
        _observerPort > 0) {
      _udp!.send([80, 83, 85, 49, ..._cookie!], _observer!, _observerPort);
    }
    if (_ready.isCompleted && _candidate != null && _ticks % 2 == 0) {
      final random = Random.secure();
      _ping = List.generate(8, (_) => random.nextInt(256));
      _pingAt = DateTime.now();
      _queue(3, _ping!, udp: true);
    }
    final value = _direct ? SteamInternetPath.direct : SteamInternetPath.relay;
    if (path.value != value) path.value = value;
  }

  void resetNativeClients() => _nativePorts.fillRange(0, 6, null);
  void close() {
    if (_closed) return;
    _closed = true;
    _tick?.cancel();
    _batchTimer?.cancel();
    _handshakeDeadline?.cancel();
    _attempt?.cancel();
    _codec?.close();
    _incoming.clear();
    _outgoing.clear();
    _batch.clear();
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _subscriptions.clear();
    for (final s in _local) {
      s.close();
    }
    _udp?.close();
    unawaited(_socket?.close().catchError((Object _) {}));
    if (!_ready.isCompleted) _ready.completeError(const SocketException('Steam internet unavailable'));
    _done.complete();
    // Consumers may still read the final route after disconnect; its notifier
    // owns no timer/transport and is disposed by its session owner.
  }
}

/// Discovery is only a routing hint. A response must match the chosen Steam
/// host ID and address; Steam's native pairing still authorizes the session.
Future<bool> steamHostReachable(GameHost host) async {
  RawDatagramSocket? socket;
  StreamSubscription<RawSocketEvent>? subscription;
  try {
    final addresses = await InternetAddress.lookup(
      host.address,
      type: InternetAddressType.IPv4,
    ).timeout(const Duration(seconds: 1));
    if (addresses.isEmpty) return false;
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final done = Completer<bool>();
    subscription = socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        for (var n = 0; n < 32; n++) {
          final d = socket!.receive();
          if (d == null) break;
          if (d.port == host.port &&
              addresses.any((a) => a.address == d.address.address) &&
              SteamDiscoveryCodec.decode(d.data)?.id == host.id &&
              !done.isCompleted) {
            done.complete(true);
          }
        }
      },
      onError: (Object _) {
        if (!done.isCompleted) done.complete(false);
      },
    );
    socket.send(SteamDiscoveryCodec.query(Random.secure().nextInt(0x7fffffff) + 1), addresses.first, host.port);
    return await done.future.timeout(const Duration(milliseconds: 900), onTimeout: () => false);
  } catch (_) {
    return false;
  } finally {
    await subscription?.cancel();
    socket?.close();
  }
}
