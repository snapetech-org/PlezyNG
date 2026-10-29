import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'romm_models.dart';

/// A connection owns its HTTP pool. Cancelling a retired profile aborts reads,
/// downloads and authorization polling without sharing credentials elsewhere.
class RommClient {
  RommClient(this.base, {this.token = '', HttpClient? http}) : _http = http ?? HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 15);
    _http.idleTimeout = const Duration(seconds: 20);
    _http.maxConnectionsPerHost = 6;
  }
  final Uri base;
  final String token;
  final HttpClient _http;
  bool _closed = false;
  bool get closed => _closed;
  void close() { _closed = true; _http.close(force: true); }
  void requireCurrent() { if (_closed) throw const RommFailure('romm.cancelled'); }

  Uri uri(String path, [Map<String, Object?> query = const {}]) {
    if (path.startsWith('/') || path.contains('\\') || path.split('/').contains('..')) {
      throw const RommFailure('romm.invalidAddress');
    }
    final result = base.resolve(path);
    if (result.origin != base.origin || !result.path.startsWith(base.path)) throw const RommFailure('romm.invalidAddress');
    return query.isEmpty ? result : result.replace(queryParameters: {
      for (final entry in query.entries) if (entry.value != null) entry.key: entry.value.toString(),
    });
  }

  /// Resolves server-relative art and asset links without allowing a token to
  /// follow an external origin, path traversal, or a credential-bearing URL.
  Uri resource(String path) {
    final parsed = Uri.tryParse(path);
    if (parsed == null || parsed.userInfo.isNotEmpty || parsed.hasFragment ||
        parsed.pathSegments.any((p) => p == '..' || p.contains('\\'))) throw const RommFailure('romm.invalidAddress');
    final normalized = parsed.scheme.isEmpty && parsed.path.startsWith('/') && !parsed.path.startsWith(base.path)
        ? parsed.replace(path: '${base.path}${parsed.path.substring(1)}') : parsed;
    final resolved = base.resolveUri(normalized);
    if (resolved.origin != base.origin || !resolved.path.startsWith(base.path)) throw const RommFailure('romm.invalidAddress');
    return resolved;
  }

  Future<HttpClientRequest> open(String method, Uri url, {Map<String, String> headers = const {}}) async {
    requireCurrent();
    if (url.origin != base.origin || !url.path.startsWith(base.path) || url.userInfo.isNotEmpty) {
      throw const RommFailure('romm.invalidAddress');
    }
    final request = await _http.openUrl(method, url).timeout(const Duration(seconds: 20));
    requireCurrent();
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (token.isNotEmpty) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    for (final entry in headers.entries) request.headers.set(entry.key, entry.value);
    return request;
  }

  Future<Uint8List> read(HttpClientResponse response, {int maximum = 8 * 1024 * 1024}) async {
    if (response.contentLength > maximum) throw const RommFailure('romm.responseTooLarge');
    final data = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      requireCurrent();
      if (data.length + chunk.length > maximum) throw const RommFailure('romm.responseTooLarge');
      data.add(chunk);
    }
    return data.takeBytes();
  }

  Future<Object?> json(String method, String path, {Map<String, Object?> query = const {}, Object? body}) async {
    final request = await open(method, uri('api/$path', query));
    if (body != null) { request.headers.contentType = ContentType.json; request.write(jsonEncode(body)); }
    final response = await request.close().timeout(const Duration(seconds: 30));
    final bytes = await read(response);
    Object? data;
    try { if (bytes.isNotEmpty) data = jsonDecode(utf8.decode(bytes)); } catch (_) { throw const RommFailure('romm.invalidResponse'); }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = rommString(rommMap(data)['detail'], 80);
      throw RommFailure({'authorization_pending', 'slow_down', 'access_denied', 'expired_token'}.contains(code)
          ? code : response.statusCode == 401 ? 'romm.signInAgain' : response.statusCode == 403
          ? 'romm.permissionDenied' : response.statusCode == 409 ? 'romm.conflict'
          : response.statusCode == 404 ? 'romm.notFound' : 'romm.serverError', status: response.statusCode);
    }
    return data;
  }

  Future<Map<String, dynamic>> getMap(String path, {Map<String, Object?> query = const {}}) async =>
      rommMap(await json('GET', path, query: query));
  Future<Map<String, dynamic>> me() => getMap('users/me');
  Future<Map<String, dynamic>> heartbeat() => getMap('heartbeat');
  Future<Map<String, dynamic>> config() => getMap('config');
  Future<Map<String, dynamic>> streaming() => getMap('streaming/config');

  Future<Map<String, dynamic>> startPairing(String identifier, String name) async => rommMap(await json(
    'POST', 'auth/device/init', body: {'client_device_identifier': identifier, 'name': name,
      'client': 'PlezyNG', 'platform': Platform.operatingSystem, 'client_version': '1',
      'requested_scopes': ['roms.read', 'roms.user.read', 'roms.user.write', 'assets.read', 'assets.write',
        'platforms.read', 'collections.read', 'collections.write', 'devices.read', 'devices.write']}));
  Future<Map<String, dynamic>> pollPairing(String deviceCode) async =>
      rommMap(await json('POST', 'auth/device/token', body: {'device_code': deviceCode}));
  Future<String> exchangeCode(String code) async => rommString(
      rommMap(await json('POST', 'client-tokens/exchange', body: {'code': code}))['token'], 4096);

  Future<RommPage> games(String connection, {String search = '', int offset = 0,
      int? platformId, RommCollection? collection, bool recent = false}) async {
    final map = await getMap('roms', query: {'limit': 100, 'offset': offset, 'search_term': search,
      'platform_ids': platformId, if (collection != null) '${collection.kind}_id': collection.id,
      'order_by': recent ? 'last_played' : search.isEmpty ? 'name' : null,
      'order_dir': recent ? 'desc' : 'asc', 'last_played': recent ? true : null,
      'group_by_meta_id': false, 'with_char_index': false, 'with_filter_values': false, 'with_rom_id_index': false});
    final rows = rommList(map['items']).take(100).map((e) => RommGame.fromJson(connection, rommMap(e))).where((g) => g.id > 0).toList();
    final total = rommInt(map['total'], offset + rows.length);
    return RommPage(rows, total, rows.isNotEmpty && offset + rows.length < total ? offset + rows.length : null);
  }
  Future<RommGame> game(String connection, int id) async => RommGame.fromJson(connection, await getMap('roms/$id'));
  Future<List<Map<String, dynamic>>> platforms() async => rommList(await json('GET', 'platforms')).map(rommMap).toList();
  Future<List<RommCollection>> collections() async {
    final result = <RommCollection>[];
    for (final route in {'collections': 'collection', 'collections/smart': 'smart_collection', 'collections/virtual': 'virtual_collection'}.entries) {
      try { result.addAll(rommList(await json('GET', route.key)).take(1000).map((e) => RommCollection.fromJson(rommMap(e), route.value))); }
      on RommFailure catch (error) { if (error.status != 404 && error.status != 403) rethrow; }
    }
    return result;
  }
  Future<void> setProgress(RommGame game, Map<String, dynamic> props, {bool played = false}) async {
    await json('PUT', 'roms/${game.id}/props', query: {if (played) 'update_last_played': true}, body: props);
  }
  Future<void> recordPlay(RommGame game, String deviceId, DateTime start, DateTime end) async {
    if (end.difference(start).inSeconds < 1) return;
    await json('POST', 'play-sessions', body: {if (deviceId.isNotEmpty) 'device_id': deviceId,
      'sessions': [{'rom_id': game.id, 'start_time': start.toUtc().toIso8601String(),
        'end_time': end.toUtc().toIso8601String(),
        'duration_ms': end.difference(start).inMilliseconds.clamp(0, 86400000)}]});
  }
  Future<Uint8List> asset(String path, {int maximum = 12 * 1024 * 1024}) async {
    final response = await (await open('GET', resource(path))).close();
    if (response.statusCode != 200) throw RommFailure('romm.notFound', status: response.statusCode);
    return read(response, maximum: maximum);
  }
  Uri content(RommGame game, {RommFile? file}) => uri(
    'api/roms/${game.id}/content/${Uri.encodeComponent(file?.name ?? game.fileName)}',
    {if (file != null) 'file_ids': file.id});
  Future<Uint8List> saveBytes(RommSave save) async {
    final response = await (await open('GET', uri('api/${save.state ? 'states' : 'saves'}/${save.id}/content'))).close();
    if (response.statusCode != 200) throw RommFailure('romm.notFound', status: response.statusCode);
    return read(response, maximum: 128 * 1024 * 1024);
  }

  /// Upload creates a new version by default. Conflict overrides must be an
  /// explicit reviewed action; failed uploads remain in the durable outbox.
  Future<Map<String, dynamic>> uploadSave({required int romId, required String name,
      required Uint8List bytes, required String emulator, String core = '', String deviceId = '',
      String slot = 'autosave', String? contentHash, bool state = false, bool overwrite = false}) async {
    rommSafeFileName(name);
    if (bytes.length > 128 * 1024 * 1024 || !RegExp(r'^[a-zA-Z0-9_.-]{1,100}$').hasMatch(emulator)) {
      throw const RommFailure('romm.invalidFile');
    }
    final boundary = 'plezy${List.generate(24, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final request = await open('POST', uri('api/${state ? 'states' : 'saves'}', {
      'rom_id': romId, 'emulator': emulator, if (core.isNotEmpty && state) 'core': core,
      if (deviceId.isNotEmpty && !state) 'device_id': deviceId,
      if (!state) 'slot': slot, if (!state) 'autocleanup': false,
      if (!state) 'overwrite': overwrite, if (contentHash != null && !state) 'content_hash': contentHash,
    }));
    request.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$boundary');
    // RFC 7578 quoted names: quotes and CR/LF never enter multipart headers.
    final safeName = name.replaceAll('"', '_');
    final prefix = utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="${state ? 'stateFile' : 'saveFile'}"; filename="$safeName"\r\nContent-Type: application/octet-stream\r\n\r\n');
    final suffix = utf8.encode('\r\n--$boundary--\r\n');
    request.contentLength = prefix.length + bytes.length + suffix.length;
    request.add(prefix); request.add(bytes); request.add(suffix);
    final response = await request.close().timeout(const Duration(minutes: 2));
    final data = await read(response);
    if (response.statusCode == 409) throw const RommFailure('romm.conflict', status: 409);
    if (response.statusCode < 200 || response.statusCode > 299) throw RommFailure('romm.saveUploadFailed', status: response.statusCode);
    return rommMap(jsonDecode(utf8.decode(data)));
  }
}
