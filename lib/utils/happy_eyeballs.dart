import 'dart:async';
import 'dart:io';

import 'certificate_trust.dart';

/// Resolves A and AAAA independently so a slow DNS family cannot hold up a
/// reachable one. IPv4 waits at most [defaultResolutionDelay] for IPv6, then
/// candidates race [defaultAttemptDelay] apart as they become available.
/// Resolver order is preserved within each family; preserving a combined
/// RFC 6724 ranking would require waiting for both lookups.
///
/// With a factory installed the SDK no longer secures the socket itself, and
/// `badCertificateCallback`/`SecurityContext` never reach it, so TLS is done
/// here, verifying against [CertificateTrust.contextFor] the host. Proxied
/// requests are handed back plain: the SDK tunnels and secures those on its
/// own.
Future<ConnectionTask<Socket>> happyEyeballsConnectionFactory(Uri url, String? proxyHost, int? proxyPort) {
  if (proxyHost != null) return Socket.startConnect(proxyHost, proxyPort!);
  final secure = url.isScheme('https');
  // WebSocket.connect supplies port 0 when a ws/wss URL omits its port.
  // Match HttpClient's default-port substitution for direct connections.
  final port = url.port == 0 ? (secure ? HttpClient.defaultHttpsPort : HttpClient.defaultHttpPort) : url.port;
  return Future.value(startHappyEyeballsConnect(url.host, port, secure: secure));
}

/// Opens an Internet-only connection after validating both DNS families.
///
/// DNS is resolved once for the request and the winning socket connects to the
/// validated address directly. This prevents a second resolver lookup between
/// validation and connect, and rejects mixed public/private answers instead
/// of racing into whichever address happens to win. Proxy connections are
/// rejected because the proxy, rather than this process, would resolve the
/// destination.
Future<ConnectionTask<Socket>> publicInternetConnectionFactory(Uri url, String? proxyHost, int? proxyPort) {
  if (proxyHost != null) {
    return Future.error(const SocketException('Proxied public-address validation is unavailable'));
  }
  if (!const {'http', 'https'}.contains(url.scheme) || url.host.isEmpty) {
    return Future.error(const SocketException('Unsupported Internet destination'));
  }
  final secure = url.isScheme('https');
  final port = url.port == 0 ? (secure ? HttpClient.defaultHttpsPort : HttpClient.defaultHttpPort) : url.port;
  final host = url.host.replaceFirst('%25', '%');
  final literal = InternetAddress.tryParse(host);
  if (literal != null) {
    if (!_isPublicInternetAddress(literal)) {
      return Future.error(const SocketException('Destination is not a public Internet address'));
    }
    return Future.value(startHappyEyeballsConnect(host, port, secure: secure));
  }
  late final Future<({List<InternetAddress> ipv4, List<InternetAddress> ipv6})> resolved;
  resolved = _lookupPublicInternetAddresses(host);

  Future<List<InternetAddress>> lookup(String _, {required InternetAddressType type}) async {
    final addresses = await resolved;
    return type == InternetAddressType.IPv6 ? addresses.ipv6 : addresses.ipv4;
  }

  return Future.value(startHappyEyeballsConnect(host, port, secure: secure, lookup: lookup));
}

Future<({List<InternetAddress> ipv4, List<InternetAddress> ipv6})> _lookupPublicInternetAddresses(String host) async {
  final results = await Future.wait([
    InternetAddress.lookup(host, type: InternetAddressType.IPv4),
    InternetAddress.lookup(host, type: InternetAddressType.IPv6),
  ]);
  final ipv4 = results[0], ipv6 = results[1];
  final addresses = [...ipv4, ...ipv6];
  if (addresses.isEmpty || addresses.any((address) => !_isPublicInternetAddress(address))) {
    throw const SocketException('Destination does not resolve exclusively to public Internet addresses');
  }
  return (ipv4: ipv4, ipv6: ipv6);
}

bool _isPublicInternetAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    final a = bytes[0], b = bytes[1], c = bytes[2];
    if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
    if (a == 100 && b >= 64 && b <= 127) return false;
    if (a == 169 && b == 254) return false;
    if (a == 172 && b >= 16 && b <= 31) return false;
    if (a == 192 && ((b == 0 && c == 0) || b == 168 || (b == 88 && c == 99))) return false;
    if (a == 192 && b == 0 && c == 2) return false;
    if (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) return false;
    if (a == 203 && b == 0 && c == 113) return false;
    return true;
  }

  if (address.type != InternetAddressType.IPv6 || (bytes[0] & 0xe0) != 0x20) return false;
  // IETF protocol assignments (2001::/23), documentation (2001:db8::/32),
  // 6to4 (2002::/16), and the current documentation prefix (3fff::/20) are
  // not public service destinations for an add-on client.
  if (bytes[0] == 0x20 && bytes[1] == 0x01 && (bytes[2] & 0xfe) == 0) return false;
  if (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8) return false;
  if (bytes[0] == 0x20 && bytes[1] == 0x02) return false;
  if (bytes[0] == 0x3f && (bytes[1] & 0xf0) == 0xf0) return false;
  return true;
}

const Duration defaultAttemptDelay = Duration(milliseconds: 250);
const Duration defaultResolutionDelay = Duration(milliseconds: 50);

typedef AddressLookup = Future<List<InternetAddress>> Function(String host, {required InternetAddressType type});
typedef AddressConnect = Future<ConnectionTask<Socket>> Function(InternetAddress address, int port);
typedef TlsUpgrade = Future<Socket> Function(Socket socket, String host);

Future<Socket> _secureUpgrade(Socket socket, String host) =>
    SecureSocket.secure(socket, host: host, context: CertificateTrust.contextFor(host));

/// Returns synchronously so `HttpClient.connectionTimeout` and `cancel()`
/// cover the lookup as well as the connect.
///
/// The task owns the transport until it is delivered: `cancel()` is
/// idempotent, settles [ConnectionTask.socket] at once with a
/// [SocketException], destroys a raw winner that has not entered TLS yet,
/// and never touches a socket that was already delivered. dart:io exposes no
/// handle to abort `SecureSocket.secure` once it has detached the raw
/// transport (`destroy` on the plain socket is a no-op from then on), so a
/// cancel during the handshake can only settle the future and destroy
/// whatever the handshake eventually yields; the peer sees the close when the
/// handshake settles, not at the cancel. [upgrade] is that handoff, injectable
/// like [lookup] and [connect].
ConnectionTask<Socket> startHappyEyeballsConnect(
  String host,
  int port, {
  bool secure = false,
  Duration attemptDelay = defaultAttemptDelay,
  Duration resolutionDelay = defaultResolutionDelay,
  AddressLookup lookup = InternetAddress.lookup,
  AddressConnect connect = Socket.startConnect,
  TlsUpgrade upgrade = _secureUpgrade,
}) {
  final race = _Race(host, port, secure ? upgrade : null, attemptDelay, resolutionDelay, lookup, connect)..start();
  return ConnectionTask.fromSocket(race.socket, race.cancel);
}

class _Race {
  _Race(this._host, this._port, this._upgrade, this._delay, this._resolutionDelay, this._lookup, this._connect);

  final String _host;
  final int _port;

  /// Non-null for TLS: the winner is handed over here before delivery.
  final TlsUpgrade? _upgrade;
  final Duration _delay;
  final Duration _resolutionDelay;
  final AddressLookup _lookup;
  final AddressConnect _connect;

  final _result = Completer<Socket>();
  final _inFlight = <ConnectionTask<Socket>>{};
  List<InternetAddress> _ipv6 = const [];
  List<InternetAddress> _ipv4 = const [];
  int _nextIPv6 = 0;
  int _nextIPv4 = 0;
  InternetAddressType _lastFamily = InternetAddressType.IPv4;
  Timer? _timer;
  Timer? _resolutionTimer;
  int _pendingLookups = 0;
  bool _ipv6Pending = false;
  bool _started = false;
  int _pending = 0;
  Object? _error;
  StackTrace? _stackTrace;
  bool _cancelled = false;

  /// A raw connect won. With [_upgrade] the result is still pending on the
  /// handshake, but the race itself is over.
  bool _won = false;

  Future<Socket> get socket => _result.future;

  bool get _done => _cancelled || _won || _result.isCompleted;

  void start() {
    // Uri.host keeps a link-local zone percent-encoded (`fe80::1%25en0`).
    final host = _host.replaceFirst('%25', '%');
    final literal = InternetAddress.tryParse(host);
    if (literal != null) {
      if (literal.type == InternetAddressType.IPv6) {
        _ipv6 = [literal];
      } else {
        _ipv4 = [literal];
      }
      _startNext();
      return;
    }
    _pendingLookups = 2;
    _ipv6Pending = true;
    unawaited(_resolve(host, InternetAddressType.IPv6));
    unawaited(_resolve(host, InternetAddressType.IPv4));
  }

  Future<void> _resolve(String host, InternetAddressType type) async {
    try {
      final addresses = await _lookup(host, type: type);
      if (_done) return;
      if (type == InternetAddressType.IPv6) {
        _ipv6 = addresses;
      } else {
        _ipv4 = addresses;
      }
    } catch (error, stackTrace) {
      if (_done) return;
      if (!_started) {
        _error ??= error;
        _stackTrace ??= stackTrace;
      }
    }
    _pendingLookups--;
    if (type == InternetAddressType.IPv6) _ipv6Pending = false;
    if (!_started && _ipv6Pending && _ipv4.isNotEmpty) {
      _resolutionTimer ??= Timer(_resolutionDelay, _startNext);
      return;
    }
    if (_timer == null) _startNext();
  }

  bool get _hasCandidates => _nextIPv6 < _ipv6.length || _nextIPv4 < _ipv4.length;

  void _startNext() {
    _timer?.cancel();
    _timer = null;
    _resolutionTimer?.cancel();
    _resolutionTimer = null;
    if (_done) return;
    if (!_hasCandidates) {
      if (_pending == 0 && _pendingLookups == 0) {
        _result.completeError(_error ?? SocketException("Failed host lookup: '$_host'"), _stackTrace);
      }
      return;
    }
    // Alternate available families; newly resolved addresses can join a race
    // without restarting its connection-attempt delay.
    final useIPv6 = _nextIPv6 < _ipv6.length && (_lastFamily != InternetAddressType.IPv6 || _nextIPv4 == _ipv4.length);
    final address = useIPv6 ? _ipv6[_nextIPv6++] : _ipv4[_nextIPv4++];
    _lastFamily = address.type;
    if (!_started) {
      _started = true;
      // Once an address resolves, connection failures are more useful than
      // an earlier empty/failed lookup from the other family.
      _error = null;
      _stackTrace = null;
    }
    if (_hasCandidates || _pendingLookups > 0) _timer = Timer(_delay, _startNext);
    _pending++;
    unawaited(_attempt(address));
  }

  Future<void> _attempt(InternetAddress address) async {
    ConnectionTask<Socket>? task;
    try {
      task = await _connect(address, _port);
      if (_done) {
        // The connector may finish after cancellation or another winner.
        // Observe its socket before cancelling: cancellation can fail it
        // synchronously, or do nothing if it has already connected.
        final discarded = task.socket.then<void>((socket) => socket.destroy(), onError: (Object _, StackTrace _) {});
        task.cancel();
        await discarded;
        return;
      }
      _inFlight.add(task);
      final socket = await task.socket;
      _inFlight.remove(task);
      if (_done) {
        socket.destroy();
        return;
      }
      _timer?.cancel();
      _resolutionTimer?.cancel();
      _won = true;
      _cancelInFlight();
      if (_upgrade != null) {
        unawaited(_handshake(socket));
      } else {
        _result.complete(socket);
      }
      return;
    } catch (error, stackTrace) {
      _error ??= error;
      _stackTrace ??= stackTrace;
    } finally {
      _inFlight.remove(task);
      _pending--;
    }
    _startNext();
  }

  /// Owns [raw] through the handshake. A cancel that lands meanwhile has
  /// already settled [_result], so the outcome is destroyed on arrival.
  Future<void> _handshake(Socket raw) async {
    final Socket secured;
    try {
      secured = await _upgrade!(raw, _host);
    } catch (error, stackTrace) {
      raw.destroy();
      if (!_result.isCompleted) _result.completeError(error, stackTrace);
      return;
    }
    if (_result.isCompleted) {
      secured.destroy();
      return;
    }
    _result.complete(secured);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _timer?.cancel();
    _resolutionTimer?.cancel();
    _cancelInFlight();
    if (!_result.isCompleted) {
      _result.completeError(SocketException('Connection attempt cancelled, host: $_host'));
    }
  }

  void _cancelInFlight() {
    for (final task in [..._inFlight]) {
      task.cancel();
    }
    _inFlight.clear();
  }
}
