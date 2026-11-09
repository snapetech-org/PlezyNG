import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../utils/app_logger.dart';
import '../utils/bounded_http_response.dart';
import '../utils/safe_http_redirects.dart';
import 'credential_vault.dart';
import 'settings_export_service.dart';
import 'settings_service.dart';
import 'storage_service.dart';

/// Settings backup over an explicitly configured WebDAV PUT/GET endpoint.
/// The destination contains only the portable settings export: credentials,
/// server connections, download paths, and history stay local to the device.
class CloudSettingsBackupService {
  CloudSettingsBackupService({http.Client? httpClient, this.requestTimeout = const Duration(seconds: 30)})
    : _http = httpClient ?? http.Client();

  static const _urlKey = 'cloud_settings_backup_url';
  static const _usernameKey = 'cloud_settings_backup_username';
  static const _passwordKey = 'cloud_settings_backup_password';
  final Duration requestTimeout;
  static const _maxBackupBytes = 4 * 1024 * 1024;

  final http.Client _http;
  final Set<Completer<void>> _active = {};

  @visibleForTesting
  static Uri? Function(String)? debugParseUri;

  Future<CloudSettingsBackupConfiguration> loadConfiguration() async {
    final prefs = (await SettingsService.getInstance()).prefs;
    final passwordCiphertext = prefs.getString(_passwordKey) ?? '';
    final password = passwordCiphertext.isEmpty ? '' : (await CredentialVault.reveal(passwordCiphertext) ?? '');
    return CloudSettingsBackupConfiguration(
      url: prefs.getString(_urlKey) ?? '',
      username: prefs.getString(_usernameKey) ?? '',
      password: password,
    );
  }

  Future<void> saveConfiguration({required String url, required String username, required String password}) async {
    _destination(url);
    final prefs = (await SettingsService.getInstance()).prefs;
    await prefs.setString(_urlKey, url.trim());
    await prefs.setString(_usernameKey, username.trim());
    await prefs.setString(_passwordKey, password.isEmpty ? '' : await CredentialVault.protect(password));
  }

  Future<void> backUp({
    required String? expectedProfileId,
    required String? expectedOwner,
    bool Function()? isCurrentSession,
  }) async {
    final storage = await StorageService.getInstance();
    if (!_sameOwner(storage, expectedProfileId, expectedOwner, isCurrentSession: isCurrentSession)) {
      throw const CloudSettingsBackupException('The active profile changed before the backup started.');
    }
    final configuration = await loadConfiguration();
    final uri = _destination(configuration.url);
    final settings = await SettingsService.getInstance();
    String appVersion = '';
    try {
      appVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      // Version is informational and unavailable on some test or desktop hosts.
    }
    if (!_sameOwner(storage, expectedProfileId, expectedOwner, isCurrentSession: isCurrentSession)) {
      throw const CloudSettingsBackupException('The active profile changed before the backup was sent.');
    }
    final data = SettingsExportService.buildExportMap(
      settings.prefs,
      currentUserUuid: expectedOwner,
      appVersion: appVersion,
    );
    final response = await _request(
      () => _boundedRequest(
        'PUT',
        uri,
        {..._headers(configuration), 'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode(data),
        maxBytes: 64 * 1024,
      ),
    );
    if (!_sameOwner(storage, expectedProfileId, expectedOwner, isCurrentSession: isCurrentSession)) {
      throw const CloudSettingsBackupException('The active profile changed while the backup was being sent.');
    }
    if (response.statusCode != 200 && response.statusCode != 201 && response.statusCode != 204) {
      throw CloudSettingsBackupException('The WebDAV server rejected the backup (HTTP ${response.statusCode}).');
    }
  }

  Future<ImportResult> restore({
    required String? expectedProfileId,
    required String? expectedOwner,
    bool Function()? isCurrentSession,
  }) async {
    if (expectedProfileId == null || expectedProfileId.isEmpty || expectedOwner == null || expectedOwner.isEmpty) {
      throw const CloudSettingsBackupException('Sign in before restoring settings.');
    }
    final storage = await StorageService.getInstance();
    bool isOwnerCurrent() => _sameOwner(storage, expectedProfileId, expectedOwner, isCurrentSession: isCurrentSession);
    if (!isOwnerCurrent()) {
      throw const CloudSettingsBackupException('The active profile changed before the restore started.');
    }
    final configuration = await loadConfiguration();
    final uri = _destination(configuration.url);
    if (!isOwnerCurrent()) {
      throw const CloudSettingsBackupException('The active profile changed before the backup was downloaded.');
    }
    final response = await _request(
      () => _boundedRequest('GET', uri, _headers(configuration), maxBytes: _maxBackupBytes, isCurrent: isOwnerCurrent),
    );
    if (!isOwnerCurrent()) {
      throw const CloudSettingsBackupException('The active profile changed while the backup was downloading.');
    }
    if (response.statusCode != 200) {
      throw CloudSettingsBackupException(
        'The WebDAV server could not return the backup (HTTP ${response.statusCode}).',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const CloudSettingsBackupException('The remote file is not a valid settings backup.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const CloudSettingsBackupException('The remote file is not a valid settings backup.');
    }

    final settings = await SettingsService.getInstance();
    if (!isOwnerCurrent()) {
      throw const CloudSettingsBackupException('The active profile changed before the backup could be applied.');
    }
    return SettingsExportService.applyImportMap(
      decoded,
      settings.prefs,
      currentUserUuid: expectedOwner,
      isCurrent: isOwnerCurrent,
    );
  }

  bool _sameOwner(StorageService storage, String? profileId, String? owner, {bool Function()? isCurrentSession}) =>
      (isCurrentSession?.call() ?? true) &&
      storage.getActiveProfileId() == profileId &&
      storage.activeUserScope() == owner;

  Future<http.Response> _boundedRequest(
    String method,
    Uri uri,
    Map<String, String> headers, {
    String? body,
    required int maxBytes,
    bool Function()? isCurrent,
  }) async {
    final abort = Completer<void>();
    _active.add(abort);
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    final request = http.AbortableRequest(method, uri, abortTrigger: abort.future)..headers.addAll(headers);
    if (body != null) request.body = body;
    try {
      final pending = sendWithSafeRedirects(_http, request, allowCrossOrigin: false);
      return await pending
          .then((response) async {
            if (abort.isCompleted) {
              await response.stream.listen(null).cancel();
              throw http.RequestAbortedException(uri);
            }
            return readBoundedHttpResponse(response, maxBytes: maxBytes, isCurrent: isCurrent);
          })
          .timeout(
            requestTimeout,
            onTimeout: () {
              cancel();
              throw TimeoutException('Settings backup timed out');
            },
          );
    } finally {
      cancel();
      _active.remove(abort);
    }
  }

  Future<http.Response> _request(Future<http.Response> Function() send) async {
    try {
      return await send();
    } on CloudSettingsBackupException {
      rethrow;
    } catch (error) {
      // Never include the configured URL or authorization headers in logs.
      appLogger.w('Cloud settings backup request failed (${error.runtimeType})');
      throw const CloudSettingsBackupException('Could not reach the WebDAV server. Check the URL and connection.');
    }
  }

  Map<String, String> _headers(CloudSettingsBackupConfiguration configuration) {
    final headers = <String, String>{'Accept': 'application/json'};
    if (configuration.username.isNotEmpty || configuration.password.isNotEmpty) {
      headers['Authorization'] =
          'Basic ${base64Encode(utf8.encode('${configuration.username}:${configuration.password}'))}';
    }
    return headers;
  }

  Uri _destination(String input) {
    final uri = (debugParseUri ?? Uri.tryParse)(input.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const CloudSettingsBackupException('Enter an HTTPS WebDAV URL to a JSON file.');
    }
    return uri;
  }

  void dispose() {
    for (final abort in _active) {
      if (!abort.isCompleted) abort.complete();
    }
    _active.clear();
    _http.close();
  }
}

@immutable
class CloudSettingsBackupConfiguration {
  const CloudSettingsBackupConfiguration({required this.url, required this.username, required this.password});

  final String url;
  final String username;
  final String password;
}

class CloudSettingsBackupException implements Exception {
  const CloudSettingsBackupException(this.message);

  final String message;

  @override
  String toString() => 'CloudSettingsBackupException: $message';
}
