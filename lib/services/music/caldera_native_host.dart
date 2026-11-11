import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'caldera_group.dart';
import 'caldera_mesh_volume.dart';
import 'caldera_mesh_equalizer.dart';
import 'caldera_source_endpoint.dart';

abstract interface class NativeMusicGroupAvailabilityControls {
  bool get nativeMusicGroupAvailable;
  Future<void> setNativeMusicGroupAvailable(bool value, {required bool Function() current});
}

/// Native LAN membership is an explicit, profile-lifetime availability lease.
/// Its metadata and transport surface never grants media-server authority.
class CalderaMembership {
  CalderaMembership(String source, List<String> sinks) : source = source, sinks = List.unmodifiable(sinks) {
    if (!identifier(source) ||
        sinks.isEmpty ||
        sinks.length > 9 ||
        sinks.any((value) => !identifier(value)) ||
        sinks.toSet().length != sinks.length ||
        !sinks.contains(source)) {
      throw const FormatException('Invalid native membership');
    }
  }
  final String source;
  final List<String> sinks;
  String get key => '$source:${(sinks.toList()..sort()).join(',')}';
  static bool identifier(Object? value) =>
      value is String && RegExp(r'^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$').hasMatch(value);
  factory CalderaMembership.parse(Object? value) {
    if (value is! Map ||
        value['source'] is! String ||
        value['sinks'] is! List ||
        (value['sinks'] as List).any((value) => value is! String)) {
      throw const FormatException('Invalid native membership');
    }
    final source = value['source'] as String;
    final sinks = (value['sinks'] as List).cast<String>();
    // Native HTTP controllers can relay only additional sinks on the mesh.
    // Source-originated membership includes the source; both forms are valid.
    return CalderaMembership(source, [if (!sinks.contains(source)) source, ...sinks]);
  }
}

typedef CalderaNativeHostFactory =
    CalderaNativeHost Function({
      required String id,
      required String name,
      required bool Function() current,
      required CalderaSourceMetadata Function() metadata,
      required Future<void> Function(String action, int? value) control,
      required Future<void> Function(CalderaMembership membership, bool Function() current) assign,
      required void Function() onClosed,
      required CalderaEqualizerControls equalizer,
    });

class CalderaNativeHost {
  CalderaNativeHost({
    required this.id,
    required this.name,
    required this.current,
    required this.metadata,
    required this.control,
    required this.assign,
    this.onClosed,
    this.equalizer,
    this.meshPort = 1998,
    this.companionPort = 32500,
    this.advertise = true,
    CalderaDiscovery? discovery,
  }) : _discovery = discovery ?? CalderaDiscovery(),
       _membership = CalderaMembership(id, [id]);
  final String id, name;
  final CalderaEqualizerControls? equalizer;
  late final _equalizerCommands = equalizer == null ? null : CalderaMeshEqualizer(equalizer!);
  final bool Function() current;
  final CalderaSourceMetadata Function() metadata;
  final Future<void> Function(String action, int? value) control;
  final Future<void> Function(CalderaMembership membership, bool Function() current) assign;
  final void Function()? onClosed;
  final int meshPort, companionPort;
  final bool advertise;
  final CalderaDiscovery _discovery;
  late final _volumeCommands = CalderaMeshVolume(
    read: () => metadata().volume,
    write: (value) => control('setParameters', value.round()),
  );
  final _connections = <_MeshConnection>{};
  final _advertisers = <RawDatagramSocket>[];
  final _remembered = <String, CalderaNode>{};
  final _clock = Stopwatch()..start();
  HttpServer? _mesh;
  CalderaSourceEndpoint? _endpoint;
  Timer? _timer;
  StreamSubscription<List<CalderaNode>>? _discoveryEvents;
  CalderaMembership _membership;
  CalderaMembership? _pending;
  Future<void>? _assigning, _closing;
  int _revision = 0, _lastAdvertisement = -1000;
  bool _closed = false;
  bool get active => !_closed && _mesh != null && current();
  int get boundMeshPort => _mesh?.port ?? 0;
  int get boundCompanionPort => _endpoint?.boundPort ?? 0;
  CalderaMembership get membership => _membership;
  List<CalderaNode> get nodes {
    final now = DateTime.now();
    return <String, CalderaNode>{
      ..._remembered,
      for (final node in _discovery.nodes) node.id: node,
    }.values.where((node) => node.id != id && node.expires.isAfter(now)).take(64).toList();
  }

  void remember(Iterable<CalderaNode> values) {
    for (final node in values.take(8)) {
      if (CalderaMembership.identifier(node.id) &&
          node.id != id &&
          CalderaNode.privateAddress(node.address) &&
          (_remembered.length < 64 || _remembered.containsKey(node.id))) {
        _remembered[node.id] = node;
      }
    }
  }

  CalderaNode resolve(String identity) =>
      nodes.firstWhere((node) => node.id == identity, orElse: () => throw StateError('Native member unavailable'));

  Map<String, Object> advertisement(InternetAddress address) => {
    'available': true,
    'name': name,
    'interval': 1000,
    'data': {
      'proto': 'tcp',
      'port': boundMeshPort,
      'companionPort': boundCompanionPort,
      'node': {
        'version': 1,
        'uuid': id,
        'addresses': [
          {'address': address.address, 'name': 'lan'},
        ],
      },
    },
  };

  bool _allows(InternetAddress address) =>
      active &&
      CalderaNode.privateAddress(address) &&
      (nodes.any((node) => node.address.address == address.address) ||
          _connections.any((peer) => peer.identity != null && peer.address.address == address.address));

  Future<void> start() async {
    if (_closed ||
        _mesh != null ||
        !current() ||
        !CalderaMembership.identifier(id) ||
        name.isEmpty ||
        name.length > 128) {
      throw StateError('Native availability unavailable');
    }
    try {
      _discoveryEvents = _discovery.changes.listen((_) {}, onError: (Object _) => unawaited(close()));
      await _discovery.start();
      if (!current() || _closed) throw StateError('Native availability retired');
      final mesh = await HttpServer.bind(InternetAddress.anyIPv4, meshPort);
      if (!current() || _closed) {
        await mesh.close(force: true);
        throw StateError('Native availability retired');
      }
      _mesh = mesh;
      _endpoint = CalderaSourceEndpoint(
        id: id,
        peers: const {},
        allowsPeer: _allows,
        metadata: metadata,
        control: control,
        current: () => active,
        group: (source, sinks) async => _requestMembership(CalderaMembership(source, sinks)),
        port: companionPort,
      );
      await _endpoint!.start();
      if (!current() || _closed) throw StateError('Native availability retired');
      _mesh!.listen((request) => unawaited(_accept(request)), onError: (Object _) => unawaited(close()));
      if (advertise) {
        final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
        for (final interface in interfaces) {
          for (final address in interface.addresses.where(CalderaNode.privateAddress).take(1)) {
            if (_advertisers.length >= 8) break;
            final socket = await RawDatagramSocket.bind(address, 0);
            if (!active) {
              socket.close();
              throw StateError('Native availability retired');
            }
            try {
              // IP_MULTICAST_IF is 32 on Linux/Android and 9 on BSD/Windows.
              socket.setRawOption(
                RawSocketOption(0, Platform.isLinux || Platform.isAndroid ? 32 : 9, address.rawAddress),
              );
              socket.multicastHops = 1;
              socket.multicastLoopback = false;
              socket.listen((_) {}, onError: (Object _) => unawaited(close()));
              _advertisers.add(socket);
            } catch (_) {
              socket.close();
              rethrow;
            }
          }
        }
        if (_advertisers.isEmpty) throw const SocketException('No private native interface');
      }
      _tick();
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
    } catch (_) {
      await close();
      rethrow;
    }
  }

  void _send(_MeshConnection peer, String method, Object data) {
    if (peer.socket.readyState != WebSocket.open) return;
    peer.socket.add(
      jsonEncode({'method': method, 'data': data, 'source': id, 'sentAt': DateTime.now().millisecondsSinceEpoch}),
    );
  }

  void _state(_MeshConnection peer, {bool initial = false}) => _send(peer, initial ? 'SetState' : 'SetNodeState', {
    ..._volumeCommands.state(_membership.source),
    if (equalizer != null) 'equalizer': CalderaMeshEqualizer.snapshot(equalizer!.calderaEqualizer),
  });
  void _publish() {
    if (!active) return;
    for (final peer in _connections.where((peer) => peer.identity != null).toList()) {
      _state(peer);
    }
  }

  Future<void> _accept(HttpRequest request) async {
    final address = request.connectionInfo?.remoteAddress;
    if (!active ||
        address == null ||
        !CalderaNode.privateAddress(address) ||
        _connections.length >= 16 ||
        request.headers.value('Origin') != null ||
        request.uri.path != '/' ||
        request.uri.hasQuery ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = 403;
      await request.response.close();
      return;
    }
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      if (!active || _connections.length >= 16) {
        unawaited(socket.close());
        return;
      }
      final peer = _MeshConnection(socket, address, _clock.elapsedMilliseconds);
      _connections.add(peer);
      socket.pingInterval = const Duration(seconds: 2);
      socket.listen(
        (frame) {
          try {
            if (!active || frame is! String) throw const FormatException('Invalid native mesh');
            final now = _clock.elapsedMilliseconds;
            if (now - peer.budgetAt >= 1000) {
              peer.budgetAt = now;
              peer.messages = 0;
            }
            for (final message in CalderaGroupClient.meshMessages(frame)) {
              if (++peer.messages > 128) throw const FormatException('Native mesh rate exceeded');
              if (message['data'] == 'ping' && peer.identity != null) {
                peer.lastMessage = now;
                socket.add('{"data":"ping"}');
                continue;
              }
              final identity = message['source'], data = message['data'], method = message['method'];
              if (!CalderaMembership.identifier(identity) ||
                  identity == id ||
                  peer.identity != null && peer.identity != identity) {
                throw const FormatException('Native mesh identity changed');
              }
              if (peer.identity == null) {
                if (method != 'Hello' || data is! Map || data['version'] != '1.0.0') {
                  throw const FormatException('Native Hello required');
                }
                if (_connections.any(
                  (other) =>
                      !identical(other, peer) && other.identity == identity && other.address.address != address.address,
                )) {
                  throw const FormatException('Native identity address changed');
                }
                peer.identity = identity as String;
                _state(peer, initial: true);
                _send(peer, 'MeshUpdate', const []);
              } else if (CalderaMeshEqualizer.supports(method)) {
                final commands = _equalizerCommands;
                if (commands == null) throw UnsupportedError('Native equalizer unavailable');
                final operation = commands.apply(
                  method,
                  data,
                  current: () => active && _connections.contains(peer),
                  changed: _publish,
                );
                unawaited(
                  operation.catchError((Object _) {
                    _connections.remove(peer);
                    unawaited(socket.close());
                  }),
                );
              } else if (method == 'SetSinkVolume') {
                final operation = _volumeCommands.apply(
                  data,
                  current: () => active && _connections.contains(peer),
                  changed: _publish,
                );
                unawaited(
                  operation.catchError((Object _) {
                    _connections.remove(peer);
                    unawaited(socket.close());
                  }),
                );
              } else if (method == 'SetSinksForSource') {
                _requestMembership(CalderaMembership.parse(data));
                _state(peer);
              } else if (const ['Hello', 'SetState', 'SetNodeState'].contains(method)) {
                if (data is! Map || data['version'] != '1.0.0') {
                  throw const FormatException('Unsupported native mesh');
                }
              } else if (method == 'GetState') {
                _state(peer, initial: true);
              } else if (method != 'MeshUpdate') {
                throw const FormatException('Unsupported native mesh method');
              }
              peer.lastMessage = now;
            }
          } catch (_) {
            _connections.remove(peer);
            unawaited(socket.close());
          }
        },
        onDone: () => _connections.remove(peer),
        onError: (Object _) {
          _connections.remove(peer);
          unawaited(socket.close());
        },
      );
    } catch (_) {
      /* The peer disconnected during upgrade. */
    }
  }

  /// Acknowledge the reserved source before opening PCM: a native sender waits
  /// for this acknowledgement before it starts supplying the descriptor.
  void _requestMembership(CalderaMembership requested) {
    if (!active) throw StateError('Native availability retired');
    var next = requested;
    if (!next.sinks.contains(id)) {
      if (_membership.source != next.source) return;
      next = CalderaMembership(id, [id]);
    }
    final members = next.sinks.where((member) => member != id).map(resolve).toList();
    if (members.map((node) => node.address.address).toSet().length != members.length) {
      throw const FormatException('Duplicate native address');
    }
    if (next.key == _membership.key) return;
    _revision++;
    _membership = next;
    _pending = next;
    _publish();
    _drainAssignments();
  }

  void synchronize(CalderaMembership next) {
    if (!active || next.key == _membership.key) return;
    _revision++;
    _pending = null;
    _membership = next;
    _publish();
  }

  void _drainAssignments() {
    if (_assigning != null || _pending == null || !active) return;
    final next = _pending!, revision = _revision;
    _pending = null;
    bool owns() => active && revision == _revision;
    final task = Future<void>.sync(() => assign(next, owns));
    _assigning = task;
    unawaited(
      task
          .then<void>(
            (_) {
              if (owns()) _publish();
            },
            onError: (Object _) {
              if (owns()) {
                _membership = CalderaMembership(id, [id]);
                _revision++;
                _publish();
              }
            },
          )
          .whenComplete(() {
            if (identical(_assigning, task)) _assigning = null;
            _drainAssignments();
          }),
    );
  }

  void _tick() {
    if (!active) {
      unawaited(close());
      return;
    }
    final now = _clock.elapsedMilliseconds;
    for (final peer in _connections.toList()) {
      if (now - peer.lastMessage > (peer.identity == null ? 5000 : 15000)) {
        _connections.remove(peer);
        unawaited(peer.socket.close());
      }
    }
    if (now - _lastAdvertisement < 1000) return;
    _lastAdvertisement = now;
    try {
      for (final socket in _advertisers) {
        socket.send(utf8.encode(jsonEncode(advertisement(socket.address))), InternetAddress('224.0.0.234'), 44201);
      }
      for (final peer in _connections.where((peer) => peer.identity != null)) {
        peer.socket.add('{"data":"ping"}');
      }
    } catch (_) {
      unawaited(close());
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _revision++;
    _pending = null;
    _timer?.cancel();
    await _discoveryEvents?.cancel();
    _discovery.dispose();
    for (final socket in _advertisers) {
      socket.close();
    }
    _advertisers.clear();
    for (final peer in _connections) {
      unawaited(peer.socket.close());
    }
    _connections.clear();
    final mesh = _mesh;
    _mesh = null;
    await _endpoint?.close();
    await mesh?.close(force: true);
    onClosed?.call();
  }
}

class _MeshConnection {
  _MeshConnection(this.socket, this.address, this.lastMessage);
  final WebSocket socket;
  final InternetAddress address;
  String? identity;
  int lastMessage, budgetAt = 0, messages = 0;
}
