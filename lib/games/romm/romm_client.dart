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

  Future<Object?> json(String method, String path, {Map<String, Object?> query = const {}, Object? body,
      Duration timeout = const Duration(seconds: 30)}) async {
    final request = await open(method, uri('api/$path', query));
    try {
    if (body != null) { request.headers.contentType = ContentType.json; request.write(jsonEncode(body)); }
    final response = await request.close().timeout(timeout);
    final bytes = await read(response);
    Object? data;
    try { if (bytes.isNotEmpty) data = jsonDecode(utf8.decode(bytes)); }
    on FormatException {
      // Reverse proxies commonly return HTML for an expired login or outage.
      // Preserve the status so the UI can offer the correct recovery action.
      if (response.statusCode >= 200 && response.statusCode < 300) throw const RommFailure('romm.invalidResponse');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = rommMap(data)['detail'];
      if (response.statusCode == 428 && rommMap(detail)['code'] == 'memory_card_import_required') {
        throw RommFailure(rommMap(detail)['outcome'] == 'unreadable' ? 'romm.cardUnreadable' : 'romm.cardImportRequired', status: 428);
      }
      final code = rommString(detail, 80);
      throw RommFailure({'authorization_pending', 'slow_down', 'access_denied', 'expired_token'}.contains(code)
          ? code : response.statusCode == 401 ? 'romm.signInAgain' : response.statusCode == 403
          ? 'romm.permissionDenied' : response.statusCode == 409 ? (path == 'streaming/sessions' ? 'romm.busy' : 'romm.conflict')
          : response.statusCode == 404 ? 'romm.notFound' : 'romm.serverError', status: response.statusCode);
    }
    return data;
    } catch (_) { request.abort(); rethrow; }
  }

  Future<Map<String, dynamic>> getMap(String path, {Map<String, Object?> query = const {}}) async {
    final value = await json('GET', path, query: query);
    if (value is! Map) throw const RommFailure('romm.invalidResponse');
    return rommMap(value);
  }
  Future<List<dynamic>> getList(String path, {Map<String, Object?> query = const {}}) async {
    final value = await json('GET', path, query: query);
    if (value is! List) throw const RommFailure('romm.invalidResponse');
    return value;
  }
  Future<Map<String, dynamic>> me() => getMap('users/me');
  Future<Map<String, dynamic>> heartbeat() => getMap('heartbeat');
  Future<Map<String, dynamic>> config() => getMap('config');
  Future<Map<String, dynamic>> streaming() => getMap('streaming/config');

  Future<Map<String, dynamic>> startPairing(String identifier, String name) async => rommMap(await json(
    'POST', 'auth/device/init', body: {'client_device_identifier': identifier, 'name': rommString(name, 128),
      'client': 'PlezyNG', 'platform': Platform.operatingSystem, 'client_version': '1',
      'requested_scopes': ['me.read', 'roms.read', 'roms.user.read', 'roms.user.write', 'assets.read', 'assets.write',
        'platforms.read', 'firmware.read', 'collections.read', 'collections.write', 'devices.read', 'devices.write']}));
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
    if (map['items'] is! List || map['total'] is! int || rommInt(map['total'], -1) < 0 || rommList(map['items']).length > 100) {
      throw const RommFailure('romm.invalidResponse');
    }
    final rows = rommList(map['items']).map((e) => RommGame.fromJson(connection, rommMap(e))).toList();
    if (rows.any((g) => g.id <= 0) || rows.map((g) => g.id).toSet().length != rows.length) throw const RommFailure('romm.invalidResponse');
    final total = rommInt(map['total']);
    return RommPage(rows, total, rows.isNotEmpty && offset + rows.length < total ? offset + rows.length : null);
  }
  Future<RommGame> game(String connection, int id) async {
    if (id <= 0) throw const RommFailure('romm.notFound');
    final value = RommGame.fromJson(connection, await getMap('roms/$id'));
    if (value.id != id) throw const RommFailure('romm.invalidResponse');
    return value;
  }
  Future<List<Map<String, dynamic>>> platforms() async => (await getList('platforms')).map(rommMap).where((p) => rommInt(p['id']) > 0).toList();
  Future<List<RommCollection>> collections() async {
    final result = <RommCollection>[];
    for (final route in {'collections': 'collection', 'collections/smart': 'smart_collection', 'collections/virtual': 'virtual_collection'}.entries) {
      try { result.addAll((await getList(route.key)).take(1000).map((e) => RommCollection.fromJson(rommMap(e), route.value))); }
      on RommFailure catch (error) { if (error.status != 404 && error.status != 403) rethrow; }
    }
    return result;
  }
  Future<RommCollection> createFavorites() async {
    final request = await open('POST', uri('api/collections', {'is_favorite': true, 'is_public': false}));
    try {
    request.headers.set('content-type', 'application/x-www-form-urlencoded'); request.write('name=PlezyNG+Favorites');
    final response = await request.close().timeout(const Duration(seconds: 30));
    final bytes = await read(response);
    if (response.statusCode < 200 || response.statusCode > 299) throw RommFailure('romm.permissionDenied', status: response.statusCode);
    return RommCollection.fromJson(rommMap(jsonDecode(utf8.decode(bytes))), 'collection');
    } catch (_) { request.abort(); rethrow; }
  }
  Future<void> collectionMembership(RommCollection collection, int romId, bool add) async {
    if (collection.kind != 'collection' || int.tryParse(collection.id) == null) throw const RommFailure('romm.permissionDenied');
    await json(add ? 'POST' : 'DELETE', 'collections/${collection.id}/roms', body: {'rom_ids': [romId]});
  }
  Future<void> setProgress(RommGame game, Map<String, dynamic> props, {bool played = false}) async {
    await json('PUT', 'roms/${game.id}/props', query: {if (played) 'update_last_played': true}, body: props);
  }
  Future<void> recordPlay(RommGame game, String deviceId, DateTime start, DateTime end, {int? durationMs}) async {
    final elapsed = end.difference(start).inMilliseconds;
    final played = (durationMs ?? elapsed).clamp(0, elapsed < 0 ? 0 : elapsed);
    if (elapsed < 1000 || played < 1000) return;
    await json('POST', 'play-sessions', body: {if (deviceId.isNotEmpty) 'device_id': deviceId,
      'sessions': [{'rom_id': game.id, 'start_time': start.toUtc().toIso8601String(),
        'end_time': end.toUtc().toIso8601String(),
        'duration_ms': played}]});
  }
  Future<Uint8List> asset(String path, {int maximum = 12 * 1024 * 1024, bool externalImage = false}) async {
    final candidate = Uri.tryParse(path);
    if (externalImage && candidate != null && candidate.scheme == 'https' && candidate.host.isNotEmpty && candidate.userInfo.isEmpty && candidate.origin != base.origin) {
      final public = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      try {
        final request = await public.getUrl(candidate).timeout(const Duration(seconds: 20));
        request.followRedirects = false; request.headers.set('accept', 'image/*');
        final response = await request.close().timeout(const Duration(seconds: 20));
        if (response.statusCode != 200 || response.headers.contentType?.primaryType != 'image') throw const RommFailure('romm.notFound');
        return await read(response, maximum: maximum);
      } finally { public.close(force: true); }
    }
    final request = await open('GET', resource(path));
    try {
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) throw RommFailure('romm.notFound', status: response.statusCode);
    return await read(response, maximum: maximum);
    } catch (_) { request.abort(); rethrow; }
  }
  Uri content(RommGame game, {RommFile? file}) => uri(
    'api/roms/${game.id}/content/${Uri.encodeComponent(file?.name ?? game.fileName)}',
    {if (file != null) 'file_ids': file.id});
  Future<Uint8List> saveBytes(RommSave save, {String deviceId = ''}) async {
    final request = await open('GET', uri('api/${save.state ? 'states' : 'saves'}/${save.id}/content', {
      if (!save.state && deviceId.isNotEmpty) 'device_id': deviceId,
      if (!save.state) 'optimistic': false,
    }));
    try {
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) throw RommFailure('romm.notFound', status: response.statusCode);
    return await read(response, maximum: 128 * 1024 * 1024);
    } catch (_) { request.abort(); rethrow; }
  }
  Future<void> acknowledgeSave(RommSave save, String deviceId, String contentHash) async {
    if (save.state || deviceId.isEmpty) return;
    await json('POST', 'saves/${save.id}/downloaded', body: {'device_id': deviceId, 'content_hash': contentHash});
  }

  /// Upload creates a new version by default. Conflict overrides must be an
  /// explicit reviewed action; failed uploads remain in the durable outbox.
  Future<Map<String, dynamic>> uploadSave({required int romId, required String name,
      required Uint8List bytes, required String emulator, String core = '', String deviceId = '',
      String slot = 'autosave', String? contentHash, bool state = false, bool overwrite = false}) async {
    rommSafeFileName(name);
    if (bytes.isEmpty || bytes.length > 128 * 1024 * 1024 || !RegExp(r'^[a-zA-Z0-9_.-]{1,50}$').hasMatch(emulator) ||
        !RegExp(r'^[a-zA-Z0-9_.-]{1,255}$').hasMatch(slot)) {
      throw const RommFailure('romm.invalidFile');
    }
    final boundary = 'plezy${List.generate(24, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final request = await open('POST', uri('api/${state ? 'states' : 'saves'}', {
      'rom_id': romId, 'emulator': emulator,
      if (deviceId.isNotEmpty && !state) 'device_id': deviceId,
      if (!state) 'slot': slot, if (!state) 'autocleanup': false,
      if (!state) 'overwrite': overwrite, if (contentHash != null && !state) 'content_hash': contentHash,
    }));
    try {
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
    var saved = rommMap(jsonDecode(utf8.decode(data)));
    final id = rommInt(saved['id']);
    if (id == 0 || rommInt(saved['rom_id']) != romId || saved['emulator'] != emulator) throw const RommFailure('romm.invalidResponse');
    if (state && core.isNotEmpty) {
      // The upload endpoint has no writable core parameter. Preserve the
      // declared identity using RomM's supported asset-annotation API instead.
      final label = 'Plezy core: ${rommString(core, 100)}';
      final labels = rommList(saved['labels']).whereType<String>().where((v) => !v.startsWith('Plezy core: ')).take(19).toList();
      saved = rommMap(await json('PUT', 'states/$id/labels', body: {'labels': [...labels, label]}));
      if (rommInt(saved['id']) != id || rommInt(saved['rom_id']) != romId) throw const RommFailure('romm.invalidResponse');
    }
    return saved;
    } catch (_) { request.abort(); rethrow; }
  }
}
