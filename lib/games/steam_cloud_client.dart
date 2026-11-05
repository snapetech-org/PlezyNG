import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../services/plezy_server.dart';
import '../services/trackers/oauth_proxy_client.dart';
import '../utils/platform_http_client_stub.dart'
    if (dart.library.io) '../utils/platform_http_client_io.dart'
    as platform;

const steamCloudMaxFileBytes = 8 * 1024 * 1024;
final _cloudGrant = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _cloudHash = RegExp(r'^[a-fA-F0-9]{40}$');

class SteamCloudUnavailable implements Exception {
  const SteamCloudUnavailable({this.refreshRequired = false});
  final bool refreshRequired;
  @override
  String toString() => 'Steam Cloud unavailable';
}

class SteamCloudCapabilities {
  const SteamCloudCapabilities({required this.read, required this.write});
  final bool read, write;
}

class SteamCloudFile {
  const SteamCloudFile({required this.name, required this.size, required this.sha, required this.modified});
  final String name, sha;
  final int size;
  final DateTime modified;

  factory SteamCloudFile.fromJson(Map<String, dynamic> json) {
    final name = json['name'], size = json['size'], sha = json['sha'], modified = json['modified'];
    if (name is! String ||
        name.isEmpty ||
        utf8.encode(name).length > 1024 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
        size is! int ||
        size < 0 ||
        size > 0xffffffff ||
        sha is! String ||
        !_cloudHash.hasMatch(sha) ||
        modified is! int ||
        modified < 0 ||
        modified > 253402300799) {
      throw const SteamCloudUnavailable();
    }
    return SteamCloudFile(
      name: name,
      size: size,
      sha: sha.toLowerCase(),
      modified: DateTime.fromMillisecondsSinceEpoch(modified * 1000, isUtc: true),
    );
  }
}

/// A separate, ephemeral Cloud capability. Catalog tokens only start the
/// consent flow; they never authorize file reads or writes. Nothing is saved.
class SteamCloudClient {
  SteamCloudClient({http.Client? httpClient, Uri? baseUri, Duration requestTimeout = const Duration(seconds: 125)})
    : _http = httpClient ?? platform.createPlatformClient(),
      _base = baseUri ?? Uri.parse(plezyServerBaseUrl),
      _timeout = requestTimeout;
  final http.Client _http;
  final Uri _base;
  final Duration _timeout;
  final _aborts = <Completer<void>>{};
  String? _grant;
  int? _appId;
  String? _steamId;
  bool _write = false, _disposed = false;
  Future<void>? _retirement;

  bool get canWrite => !_disposed && _write && _grant != null;

  Future<Map<String, dynamic>> _request(
    String path,
    String credential,
    Map<String, dynamic>? body, {
    String method = 'POST',
    bool retiring = false,
    bool optionalCapability = false,
    int maximum = 2 * 1024 * 1024,
  }) async {
    if ((!retiring && _disposed) ||
        _base.scheme != 'https' ||
        _base.host.isEmpty ||
        _base.userInfo.isNotEmpty ||
        _base.hasQuery ||
        _base.hasFragment ||
        !_cloudGrant.hasMatch(credential)) {
      throw const SteamCloudUnavailable();
    }
    final abort = Completer<void>();
    final request =
        http.AbortableRequest(
            method,
            _base.replace(path: '${_base.path.replaceFirst(RegExp(r'/$'), '')}$path'),
            abortTrigger: abort.future,
          )
          ..followRedirects = false
          ..headers['Authorization'] = 'Bearer $credential';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    void stop() {
      if (!abort.isCompleted) abort.complete();
    }

    if (!retiring) _aborts.add(abort);
    try {
      return await (() async {
        final response = await _http.send(request);
        if (optionalCapability && (response.statusCode == 404 || response.statusCode == 501)) {
          stop();
          return const <String, dynamic>{};
        }
        if (response.statusCode != 200 && response.statusCode != 204) {
          stop();
          throw SteamCloudUnavailable(refreshRequired: response.statusCode == 409);
        }
        if (response.contentLength != null && response.contentLength! > maximum) throw const SteamCloudUnavailable();
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (chunk.length > maximum - bytes.length) throw const SteamCloudUnavailable();
          bytes.add(chunk);
        }
        if (!retiring && _disposed) throw const SteamCloudUnavailable();
        if (response.statusCode == 204) return const <String, dynamic>{};
        final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
        if (decoded is! Map<String, dynamic>) throw const SteamCloudUnavailable();
        return decoded;
      })().timeout(
        retiring ? const Duration(seconds: 5) : _timeout,
        onTimeout: () {
          stop();
          throw const SteamCloudUnavailable();
        },
      );
    } on SteamCloudUnavailable {
      rethrow;
    } catch (_) {
      throw const SteamCloudUnavailable();
    } finally {
      _aborts.remove(abort);
      stop();
    }
  }

  Future<SteamCloudCapabilities> capabilities(String catalog, int appId) async {
    final body = await _request('/auth/steam/cloud/capabilities', catalog, {'appId': appId}, optionalCapability: true);
    if (body.isEmpty) return const SteamCloudCapabilities(read: false, write: false);
    if (body['appId'] != appId ||
        body['read'] is! bool ||
        body['write'] is! bool ||
        body['maxFileBytes'] != steamCloudMaxFileBytes) {
      throw const SteamCloudUnavailable();
    }
    return SteamCloudCapabilities(read: body['read'] == true, write: body['read'] == true && body['write'] == true);
  }

  Future<OAuthProxyStart> start(String catalog, int appId, {bool write = false}) async {
    final body = await _request('/auth/steam/cloud/start', catalog, {'appId': appId, 'write': write});
    final session = body['session'], url = body['url'];
    final uri = url is String ? Uri.tryParse(url) : null;
    if (session is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{24}$').hasMatch(session) ||
        uri == null ||
        uri.origin != _base.origin ||
        uri.path != '${_base.path.replaceFirst(RegExp(r'/$'), '')}/auth/steam-cloud' ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        uri.queryParametersAll.length != 1 ||
        uri.queryParametersAll['state']?.length != 1 ||
        !RegExp(r'^[A-Za-z0-9_-]{24}$').hasMatch(uri.queryParameters['state'] ?? '')) {
      throw const SteamCloudUnavailable();
    }
    return OAuthProxyStart(session: session, url: url as String);
  }

  void authorize(OAuthProxyResult result, {required int appId, required String steamId, required bool write}) {
    if (_disposed ||
        _grant != null ||
        result.steamId != steamId ||
        !_cloudGrant.hasMatch(result.steamCloudToken ?? '') ||
        appId < 1 ||
        appId > 0xffffffff ||
        !RegExp(r'^\d{17}$').hasMatch(steamId)) {
      throw const SteamCloudUnavailable();
    }
    _grant = result.steamCloudToken;
    _appId = appId;
    _steamId = steamId;
    _write = write;
  }

  String get _credential {
    if (_disposed || _grant == null) throw const SteamCloudUnavailable();
    return _grant!;
  }

  Future<List<SteamCloudFile>> files() async {
    final body = await _request('/auth/steam/cloud/files', _credential, {'action': 'list'});
    final raw = body['files'];
    if (body['appId'] != _appId ||
        body['steamId'] != _steamId ||
        body['write'] != _write ||
        raw is! List ||
        raw.length > 2000) {
      throw const SteamCloudUnavailable();
    }
    final result = <SteamCloudFile>[], names = <String>{};
    for (final row in raw) {
      if (row is! Map<String, dynamic>) throw const SteamCloudUnavailable();
      final file = SteamCloudFile.fromJson(row);
      if (!names.add(file.name)) throw const SteamCloudUnavailable();
      result.add(file);
    }
    return List.unmodifiable(result);
  }

  Future<Uint8List> download(SteamCloudFile file) async {
    if (file.size > steamCloudMaxFileBytes) throw const SteamCloudUnavailable();
    final body = await _request('/auth/steam/cloud/files', _credential, {
      'action': 'download',
      'filename': file.name,
      'expectedSha': file.sha,
    }, maximum: 12 * 1024 * 1024);
    final encoded = body['data'];
    if (body['name'] != file.name ||
        body['sha'] != file.sha ||
        encoded is! String ||
        encoded.length > 12 * 1024 * 1024) {
      throw const SteamCloudUnavailable();
    }
    try {
      final bytes = base64Decode(encoded);
      if (bytes.length != file.size || crypto.sha1.convert(bytes).toString() != file.sha) {
        throw const SteamCloudUnavailable();
      }
      return bytes;
    } catch (_) {
      throw const SteamCloudUnavailable();
    }
  }

  Future<void> replace(SteamCloudFile file, Uint8List data) async {
    if (!canWrite || data.length > steamCloudMaxFileBytes) throw const SteamCloudUnavailable();
    final result = await _request('/auth/steam/cloud/files', _credential, {
      'action': 'upload',
      'filename': file.name,
      'expectedSha': file.sha,
      'data': base64Encode(data),
    });
    if (result['completed'] != true) throw const SteamCloudUnavailable(refreshRequired: true);
  }

  Future<void> delete(SteamCloudFile file) async {
    if (!canWrite) throw const SteamCloudUnavailable();
    final result = await _request('/auth/steam/cloud/files', _credential, {
      'action': 'delete',
      'filename': file.name,
      'expectedSha': file.sha,
    });
    if (result['completed'] != true) throw const SteamCloudUnavailable(refreshRequired: true);
  }

  Future<void> retire() => _retirement ??= _close();
  Future<void> _close() async {
    _disposed = true;
    for (final abort in _aborts) {
      if (!abort.isCompleted) abort.complete();
    }
    _aborts.clear();
    final grant = _grant;
    _grant = null;
    _write = false;
    try {
      if (grant != null) await _request('/auth/steam/cloud/files', grant, null, method: 'DELETE', retiring: true);
    } catch (_) {
      /* The server's grant TTL also retires disconnected clients. */
    } finally {
      _http.close();
    }
  }
}
