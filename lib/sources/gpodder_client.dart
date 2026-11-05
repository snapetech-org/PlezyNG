import 'dart:convert';

import 'source_models.dart';
import 'source_transport.dart';

final class GpodderConfig {
  GpodderConfig({required this.endpoint, required this.username, required this.password, required this.device,
    this.subscriptions = true, this.progress = true}) {
    final uri = Uri.tryParse(endpoint);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment ||
        endpoint.length > 2048 || username.isEmpty || username.length > 128 || username.contains(RegExp(r'[:\x00-\x1f]')) ||
        password.isEmpty || password.length > 4096 || !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(device)) {
      throw const SourceException(SourceFailure.invalidData);
    }
  }
  final String endpoint, username, password, device;
  final bool subscriptions, progress;
  factory GpodderConfig.fromJson(Map<String, dynamic> value) => GpodderConfig(
    endpoint: value['endpoint'] as String, username: value['username'] as String,
    password: value['password'] as String, device: value['device'] as String,
    subscriptions: value['subscriptions'] != false, progress: value['progress'] != false);
  Map<String, dynamic> toJson() => {'endpoint': endpoint, 'username': username, 'password': password,
    'device': device, 'subscriptions': subscriptions, 'progress': progress};
}

typedef GpodderSubscriptions = ({List<String> add, List<String> remove, int timestamp});
typedef GpodderActions = ({List<Map<String, dynamic>> actions, int timestamp});

String podcastSyncUrlIdentity(String value) {
  final uri = Uri.parse(GpodderClient.validateUrl(value));
  final query = <String, dynamic>{};
  final keys = uri.queryParametersAll.keys.where((key) => !sourceCredentialParameter.hasMatch(key)).toList()..sort();
  for (final key in keys) { query[key] = uri.queryParametersAll[key]!; }
  return uri.replace(queryParameters: query).toString();
}
String podcastSyncIdentity(String feed, String episode) =>
    sourceDigest('${podcastSyncUrlIdentity(feed)}\u0000${podcastSyncUrlIdentity(episode)}');

/// gpodder.net API v2 and compatible self-hosted servers. Authentication never
/// follows a redirect and is never attached to feed or enclosure requests.
final class GpodderClient {
  GpodderClient(this.config, {SourceTransport? transport, void Function()? check})
      : _transport = transport ?? SourceTransport(), _check = check ?? _noop;
  final GpodderConfig config;
  final SourceTransport _transport;
  final void Function() _check;
  static void _noop() {}
  String get _user => Uri.encodeComponent(config.username);
  String get _device => Uri.encodeComponent(config.device);
  Uri _uri(String relative, [Map<String, String>? query]) =>
      Uri.parse('${config.endpoint.replaceFirst(RegExp(r'/+$'), '')}/$relative').replace(queryParameters: query);

  Future<Map<String, dynamic>> _json(String method, String relative, {Object? body, Map<String, String>? query}) async {
    _check();
    final encoded = body == null ? null : jsonEncode(body);
    if (encoded != null && utf8.encode(encoded).length > 2 * 1024 * 1024) throw const SourceException(SourceFailure.invalidData);
    final text = await _transport.text(method, _uri(relative, query), headers: {
      'Authorization': 'Basic ${base64Encode(utf8.encode('${config.username}:${config.password}'))}',
      'Accept': 'application/json', 'Content-Type': 'application/json', 'User-Agent': 'PlezyNG/3 podcast-sync',
    }, body: encoded, limit: 2 * 1024 * 1024);
    _check();
    if (text.trim().isEmpty) return {};
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic>) throw const SourceException(SourceFailure.invalidData);
    return value;
  }
  Future<void> verifyLogin() async { await _json('POST', 'api/2/auth/$_user/login.json'); }

  static int _timestamp(Map<String, dynamic> value, int since) {
    final timestamp = value['timestamp'];
    if (timestamp is! int || since < 0 || timestamp < since || timestamp > 9007199254740991) throw const SourceException(SourceFailure.invalidData);
    return timestamp;
  }
  static String validateUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !const {'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.hasFragment || value.length > 8192) throw const SourceException(SourceFailure.invalidData);
    return uri.toString();
  }
  static List<String> _urls(Object? raw) {
    if (raw is! List || raw.length > 500 || raw.any((value) => value is! String)) throw const SourceException(SourceFailure.invalidData);
    return raw.cast<String>().map(validateUrl).toSet().toList();
  }
  Future<GpodderSubscriptions> subscriptionChanges(int since) async {
    final value = await _json('GET', 'api/2/subscriptions/$_user/$_device.json', query: {'since': '$since'});
    return (add: _urls(value['add']), remove: _urls(value['remove']), timestamp: _timestamp(value, since));
  }
  Future<Map<String, String>> publishSubscriptions({required List<String> add, required List<String> remove}) async {
    if (add.toSet().intersection(remove.toSet()).isNotEmpty) throw const SourceException(SourceFailure.invalidData);
    final value = await _json('POST', 'api/2/subscriptions/$_user/$_device.json', body: {'add': _urls(add), 'remove': _urls(remove)});
    return _rewrites(value);
  }
  Future<GpodderActions> episodeActions(int since) async {
    final value = await _json('GET', 'api/2/episodes/$_user.json', query: {'since': '$since', 'aggregated': 'true'});
    final actions = value['actions'];
    if (actions is! List || actions.length > 5000 || actions.any((value) => value is! Map)) throw const SourceException(SourceFailure.invalidData);
    return (actions: actions.map((action) => sourceMap(action)).toList(), timestamp: _timestamp(value, since));
  }
  Future<Map<String, String>> publishActions(List<Map<String, dynamic>> actions) async {
    if (actions.isEmpty || actions.length > 500) throw const SourceException(SourceFailure.invalidData);
    return _rewrites(await _json('POST', 'api/2/episodes/$_user.json', body: actions));
  }
  static Map<String, String> _rewrites(Map<String, dynamic> value) {
    final rows = value['update_urls'] ?? const [];
    if (rows is! List || rows.length > 5000) throw const SourceException(SourceFailure.invalidData);
    final result = <String, String>{};
    for (final row in rows) {
      if (row is! List || row.length != 2 || row[0] is! String || row[1] is! String) throw const SourceException(SourceFailure.invalidData);
      final from = validateUrl(row[0] as String), to = row[1] as String;
      result[from] = to.isEmpty ? '' : validateUrl(to);
    }
    return result;
  }
  void close() => _transport.close();
}
