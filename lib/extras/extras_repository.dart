import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'extras_models.dart';
import 'extras_policy.dart';
import 'extras_store.dart';

/// HTTPS, or an explicitly configured local network helper. No credentials in
/// URLs; redirects are disabled at the request boundary.
Uri? extrasServiceUri(String raw, {bool deviceOnly = false}) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
    return null;
  }
  final host = uri.host.toLowerCase();
  final loopback = host == 'localhost' || host == '127.0.0.1' || host == '[::1]' || host == '::1';
  if (deviceOnly && !loopback) return null;
  final parts = host.split('.').map(int.tryParse).toList();
  final private =
      parts.length == 4 &&
      parts.every((p) => p != null && p >= 0 && p <= 255) &&
      (parts[0] == 10 ||
          (parts[0] == 192 && parts[1] == 168) ||
          (parts[0] == 172 && parts[1]! >= 16 && parts[1]! <= 31));
  if (uri.scheme != 'https' && !(uri.scheme == 'http' && (loopback || private))) {
    return null;
  }
  return uri.replace(path: uri.path.endsWith('/') ? uri.path : '${uri.path}/');
}

Future<Map<String, dynamic>> extrasJsonRequest(
  http.Client client,
  Uri uri,
  Map<String, Object?> body, {
  String token = '',
  Duration timeout = const Duration(seconds: 12),
}) async {
  final aborted = Completer<void>();
  final timer = Timer(timeout, () {
    if (!aborted.isCompleted) aborted.complete();
  });
  try {
    final request = http.AbortableRequest('POST', uri, abortTrigger: aborted.future)
      ..followRedirects = false
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'application/json'
      ..body = jsonEncode(body);
    if (token.isNotEmpty) request.headers['Authorization'] = 'Bearer $token';
    final response = await client.send(request).timeout(timeout);
    if (response.statusCode != 200) {
      unawaited(response.stream.listen((_) {}).cancel());
      throw StateError('Extras service response ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(timeout)) {
      if (bytes.length + chunk.length > 1024 * 1024) {
        throw const FormatException('Extras response too large');
      }
      bytes.addAll(chunk);
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid extras response');
    }
    return decoded;
  } finally {
    timer.cancel();
    if (!aborted.isCompleted) aborted.complete();
  }
}

class ExtrasResult {
  const ExtrasResult(this.entries, {this.serviceUnavailable = false, this.cached = false});
  final List<ExtraEntry> entries;
  final bool serviceUnavailable, cached;
}

class ExtrasRepository {
  ExtrasRepository(this.store, {http.Client? client}) : _client = client ?? http.Client();
  final ExtrasStore store;
  final http.Client _client;
  final _pending = <String, Future<ExtrasResult>>{};
  bool _closed = false;
  void close() {
    _closed = true;
    _client.close();
  }

  Future<ExtrasResult> load(
    ExtrasSubject subject, {
    List<ExtraEntry> library = const [],
    List<ExtraEntry> catalog = const [],
    bool findMore = false,
    String query = '',
  }) async {
    final prefs = await store.preferences();
    final local = [...library, ...await store.personalEntries()];
    List<ExtraEntry> selected(Iterable<ExtraEntry> entries) =>
        const ExtrasPolicy().select([...local, ...entries], subject, prefs);
    final endpoint = extrasServiceUri(prefs.serviceUrl);
    if (_closed ||
        !prefs.externalEnabled ||
        subject.restricted ||
        subject.offline ||
        subject.identities.isEmpty ||
        endpoint == null) {
      return ExtrasResult(selected(const []));
    }
    final identities = subject.identities.toList()..sort();
    final cacheKey = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              endpoint.toString(),
              identities,
              subject.language,
              subject.region,
              prefs.includeAnalysis,
              findMore,
              query.trim().toLowerCase(),
            ]),
          ),
        )
        .toString();
    final cached = await store.cache(cacheKey);
    if (cached != null && DateTime.now().difference(cached.fetched) < const Duration(hours: 12)) {
      return ExtrasResult(selected(cached.entries), cached: true);
    }
    // Per-repository coalescing avoids duplicate calls from responsive rebuilds.
    final pending = _pending[cacheKey] ??= () async {
      try {
        final response = await extrasJsonRequest(_client, endpoint.resolve('v1/discover'), {
          ...subject.toRequest(),
          'expand': findMore,
          'query': query.substring(0, query.length.clamp(0, 200)),
          'includeAnalysis': prefs.includeAnalysis,
          'candidates': catalog.take(40).map((e) => e.toJson()).toList(),
        }, token: await store.secret('discovery'));
        if (response['version'] != 1 || response['entries'] is! List) {
          throw const FormatException('Unsupported extras protocol');
        }
        final entries = (response['entries'] as List).take(80).map(ExtraEntry.parse).whereType<ExtraEntry>().toList();
        final partial = response['partial'] == true;
        // An upstream failure must remain retryable and must not replace a
        // previously complete cache with an incomplete or empty selection.
        if (!_closed && !partial) await store.saveCache(cacheKey, entries);
        return ExtrasResult(entries, serviceUnavailable: partial);
      } catch (_) {
        return ExtrasResult(cached?.entries ?? const [], serviceUnavailable: true, cached: cached != null);
      }
    }();
    try {
      final result = await pending;
      return ExtrasResult(
        selected(result.entries),
        serviceUnavailable: result.serviceUnavailable,
        cached: result.cached,
      );
    } finally {
      if (identical(_pending[cacheKey], pending)) {
        unawaited(_pending.remove(cacheKey));
      }
    }
  }
}
