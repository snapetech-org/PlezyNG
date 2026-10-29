import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'romm_client.dart';
import 'romm_models.dart';

/// A private loopback origin per player. Only native code sees the RomM token.
/// An expiring, one-use bootstrap installs a session cookie; Host, Origin and
/// Fetch Metadata checks prevent other websites from borrowing this authority.
class RommPlayerProxy {
  RommPlayerProxy._(this.upstream, this._api, this.current, this._secret);
  final Uri upstream;
  final RommClient _api;
  final bool Function() current;
  final String _secret;
  String get _cookieName => 'plezy_${_server!.port}';
  HttpServer? _server;
  final _sockets = <WebSocket>{};
  final _roomCookies = <String, String>{};
  bool _booted = false, _closed = false;
  late final DateTime _expires = DateTime.now().add(const Duration(minutes: 1));
  Uri get origin => Uri(scheme: 'http', host: '127.0.0.1', port: _server!.port);
  bool get live => !_closed && current();
  static String _random() => base64Url.encode(List.generate(32, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
  static Future<RommPlayerProxy> start({required Uri upstream, String token = '', int port = 0, required bool Function() current}) async {
    if (!{'http', 'https'}.contains(upstream.scheme) || upstream.host.isEmpty || upstream.userInfo.isNotEmpty) {
      throw const RommFailure('romm.invalidAddress');
    }
    final base = upstream.replace(path: upstream.path.endsWith('/') ? upstream.path : '/', query: null, fragment: null);
    final proxy = RommPlayerProxy._(base, RommClient(base, token: token), current, _random());
    proxy._server = await HttpServer.bind(InternetAddress.loopbackIPv4, port, shared: false);
    proxy._server!.listen((request) => unawaited(proxy._serve(request)), onError: (_) => proxy.close());
    return proxy;
  }
  Uri bootstrap(String path) {
    if (!path.startsWith('/') || path.startsWith('//') || path.length > 8192) throw const RommFailure('romm.invalidAddress');
    _destination = path;
    return origin.replace(path: '/__plezy_start', queryParameters: {'key': _secret});
  }
  String _destination = '/';
  bool permits(Uri uri) => live && {'http', 'https'}.contains(uri.scheme) && uri.origin == origin.origin;
  bool _authorized(HttpRequest request) => request.cookies.any((cookie) => cookie.name == _cookieName && cookie.value == _secret);
  Future<void> _serve(HttpRequest request) async {
    try {
      if (!live || request.headers.value('host') != origin.authority) { request.response.statusCode = 403; return; }
      final incomingOrigin = request.headers.value('origin');
      if (incomingOrigin != null && incomingOrigin != origin.origin) { request.response.statusCode = 403; return; }
      if (request.headers.value('sec-fetch-site') == 'cross-site') { request.response.statusCode = 403; return; }
      if (request.uri.path == '/__plezy_start') {
        if (_booted || DateTime.now().isAfter(_expires) || request.uri.queryParameters['key'] != _secret || request.method != 'GET') {
          request.response.statusCode = 403; return;
        }
        _booted = true;
        request.response.headers.add('set-cookie', '$_cookieName=$_secret; Path=/; HttpOnly; SameSite=Strict');
        request.response.statusCode = 303; request.response.headers.set('location', _destination);
        request.response.headers.set('cache-control', 'no-store'); request.response.headers.set('referrer-policy', 'no-referrer'); return;
      }
      if (!_authorized(request)) { request.response.statusCode = 403; return; }
      final path = request.uri.path;
      if (path.contains('\\') || request.uri.pathSegments.any((s) => s == '..' || s == '.')) {
        request.response.statusCode = 400; return;
      }
      // Browser service workers cannot survive this session and intercept the
      // next account's player; native storage owns durable pending progress.
      if (request.headers.value('service-worker') == 'script') { request.response.statusCode = 403; return; }
      final relative = upstream.path != '/' && path.startsWith(upstream.path) ? path.substring(upstream.path.length) : path.replaceFirst(RegExp('^/'), '');
      final target = _api.uri(relative).replace(query: request.uri.hasQuery ? request.uri.query : null);
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        // RomM's browser netplay needs a cookie session, not this API token.
        // It is intentionally disabled; only credential-isolated stream rooms
        // use the websocket relay.
        if (_api.token.isNotEmpty) { request.response.statusCode = 403; return; }
        final remote = await WebSocket.connect(target.replace(scheme: target.scheme == 'https' ? 'wss' : 'ws').toString(),
          headers: {if (_roomCookies.isNotEmpty) 'Cookie': _roomCookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
            'Origin': upstream.origin}, protocols: request.headers.value('sec-websocket-protocol')?.split(',').map((s) => s.trim()).toList())
          .timeout(const Duration(seconds: 20));
        if (!live) { await remote.close(); return; }
        final local = await WebSocketTransformer.upgrade(request, protocolSelector: (protocols) => remote.protocol);
        _sockets.addAll([local, remote]);
        void end() { _sockets.remove(local); _sockets.remove(remote); unawaited(local.close()); unawaited(remote.close()); }
        local.listen(remote.add, onDone: end, onError: (_) => end());
        remote.listen(local.add, onDone: end, onError: (_) => end());
        return;
      }
      if (!{'GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'}.contains(request.method)) { request.response.statusCode = 405; return; }
      final forwarded = await _api.open(request.method, target);
      for (final header in ['accept', 'content-type', 'range', 'if-range', 'if-none-match', 'if-modified-since', 'x-csrftoken']) {
        final value = request.headers.value(header); if (value != null) forwarded.headers.set(header, value);
      }
      forwarded.headers.set('accept-encoding', 'identity');
      if (_roomCookies.isNotEmpty) forwarded.headers.set('cookie', _roomCookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
      if (incomingOrigin != null) forwarded.headers.set('origin', upstream.origin);
      var size = 0;
      await for (final chunk in request.timeout(const Duration(seconds: 30))) {
        if (!live) throw const RommFailure('romm.cancelled');
        size += chunk.length;
        if (size > 160 * 1024 * 1024) { forwarded.abort(); request.response.statusCode = 413; return; }
        forwarded.add(chunk);
      }
      final response = await forwarded.close().timeout(const Duration(minutes: 2));
      if (!live) return;
      for (final cookie in response.cookies) {
        if (_roomCookies.length < 32 && cookie.name.length < 128 && cookie.value.length < 4096) _roomCookies[cookie.name] = cookie.value;
      }
      request.response.statusCode = response.statusCode;
      for (final header in ['content-type', 'content-range', 'accept-ranges', 'etag', 'last-modified',
          'cross-origin-opener-policy', 'cross-origin-embedder-policy', 'cross-origin-resource-policy']) {
        final value = response.headers.value(header); if (value != null) request.response.headers.set(header, value);
      }
      request.response.headers.set('cache-control', 'no-store');
      request.response.headers.set('referrer-policy', 'no-referrer');
      request.response.headers.set('x-content-type-options', 'nosniff');
      final location = response.headers.value('location');
      if (location != null) {
        final redirected = _api.resource(location);
        final localPath = redirected.path.substring(upstream.path.length);
        request.response.headers.set('location', origin.replace(path: '/$localPath', query: redirected.hasQuery ? redirected.query : null));
      }
      // Stream ROMs and WASM; a large game must never be buffered in Dart memory.
      await request.response.addStream(response.timeout(const Duration(minutes: 2)));
    } catch (_) {
      try { request.response.statusCode = 502; } catch (_) { /* Headers already sent. */ }
    } finally {
      try { await request.response.close(); } catch (_) { /* Player already gone. */ }
    }
  }
  Future<void> close() async {
    if (_closed) return; _closed = true; _api.close(); _roomCookies.clear();
    for (final socket in _sockets.toList()) { unawaited(socket.close()); }
    _sockets.clear(); await _server?.close(force: true);
  }
}
