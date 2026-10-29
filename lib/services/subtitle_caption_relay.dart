import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../sources/sync/sync_document.dart';
import '../sources/sync/sync_store.dart';
import 'subtitle_companion_service.dart';

/// An explicit room-scoped capability. The companion administration token is
/// never included. Keep this code in memory/clipboard only, not preferences.
class SubtitleCaptionRelayInvite {
  const SubtitleCaptionRelayInvite._(this.endpoint, this.channel, this.token, this.key, this.scope, this.expires);
  final Uri endpoint;
  final String channel, token, key, scope;
  final DateTime expires;
  bool get expired => !DateTime.now().isBefore(expires);
  String encode() => 'pcap1.${base64UrlEncode(utf8.encode(jsonEncode({'version': 1, 'endpoint': endpoint.toString(),
    'channel': channel, 'token': token, 'key': key, 'scope': scope, 'expires': expires.millisecondsSinceEpoch ~/ 1000}))).replaceAll('=', '')}';
  static SubtitleCaptionRelayInvite decode(String code) {
    if (code.length > 4096 || !code.startsWith('pcap1.')) throw const FormatException('Paste a companion caption code.');
    final raw = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(code.substring(6)))));
    if (raw is! Map || raw['version'] != 1 || raw['endpoint'] is! String || raw['channel'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(raw['channel']) || raw['token'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(raw['token']) || raw['key'] is! String || raw['scope'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['scope']) || raw['expires'] is! int ||
        raw['expires'] < 0 || raw['expires'] > 253402300799) throw const FormatException('Invalid caption channel code.');
    SyncCipher.decodeCode(raw['key']);
    final invite = SubtitleCaptionRelayInvite._(SubtitleCompanionService.validateEndpoint(raw['endpoint']),
      raw['channel'], raw['token'], raw['key'], raw['scope'], DateTime.fromMillisecondsSinceEpoch(raw['expires'] * 1000, isUtc: true));
    if (invite.expired || invite.expires.isAfter(DateTime.now().add(const Duration(hours: 7)))) {
      throw const FormatException('The caption channel is expired or its clock is invalid.');
    }
    return invite;
  }
  static Future<SubtitleCaptionRelayInvite> create(SubtitleCompanionService companion, String scope) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(scope)) throw const FormatException('Invalid room scope.');
    final response = await companion.createCaptionChannel();
    if (response['version'] != 1 || response['id'] is! String || response['token'] is! String || response['expires'] is! int) {
      throw const FormatException('The companion returned an invalid caption channel.');
    }
    final encoded = base64UrlEncode(utf8.encode(jsonEncode({'version': 1, 'endpoint': companion.endpoint.toString(),
      'channel': response['id'], 'token': response['token'], 'key': SyncCipher.newCode(), 'scope': scope, 'expires': response['expires']})));
    return decode('pcap1.$encoded');
  }
}

/// Opaque AES-GCM sync envelopes over an explicitly chosen companion channel.
/// All names are immutable generations. A channel code grants shared read/write
/// access, not sender authentication, and never grants access to companion jobs.
class SubtitleCaptionRelayStore implements SyncStore {
  SubtitleCaptionRelayStore(this.invite, this.check);
  final SubtitleCaptionRelayInvite invite;
  final void Function() check;
  final Set<http.Client> _requests = {};
  final Set<String> _listed = {};
  bool _closed = false;
  static const maximumBytes = 2 * 1024 * 1024;
  void close() { _closed = true; for (final client in _requests.toList()) { client.close(); } _requests.clear(); }
  void _check() {
    check();
    if (_closed || invite.expired) throw StateError('The caption channel has expired or stopped.');
  }
  void _name(String value) {
    if (!SyncFile.pattern.hasMatch(value)) throw const FormatException('Invalid caption object name.');
  }
  Future<Map<String, dynamic>> _request(String method, String path, {Object? body, int bound = 65536}) async {
    _check();
    final client = http.Client(); _requests.add(client);
    final deadline = Timer(const Duration(seconds: 45), client.close);
    try {
      final request = http.Request(method, invite.endpoint.replace(path: '/v1/caption-relay/${invite.channel}/$path'))
        ..followRedirects = false;
      request.headers['Authorization'] = 'Bearer ${invite.token}';
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
        if (request.bodyBytes.length > maximumBytes + 65536) throw const FormatException('Caption envelope exceeds the relay bound.');
      }
      final response = await client.send(request).timeout(const Duration(seconds: 20));
      if ((response.contentLength ?? 0) > bound) throw const FormatException('Caption relay response exceeds its bound.');
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(const Duration(seconds: 20))) {
        _check();
        if (bytes.length + chunk.length > bound) throw const FormatException('Caption relay response exceeds its bound.');
        bytes.addAll(chunk);
      }
      _check();
      if (response.statusCode == 401 || response.statusCode == 404) throw StateError('The caption channel or revision has expired or was revoked.');
      if (response.statusCode == 507) throw StateError('The caption relay is full. Create a new channel or wait for expiry.');
      if (response.statusCode < 200 || response.statusCode >= 300) throw StateError('The caption relay refused the operation.');
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic>) throw const FormatException('Invalid caption relay response.');
      return value;
    } finally { deadline.cancel(); _requests.remove(client); client.close(); }
  }
  @override
  Future<List<SyncFile>> list(String namespace) async {
    if (!RegExp(r'^[a-f0-9]{24}$').hasMatch(namespace)) throw const FormatException('Invalid caption namespace.');
    final response = await _request('GET', 'list/$namespace');
    final files = response['files'];
    if (files is! List || files.length > 256) throw const FormatException('Caption relay file count exceeds its bound.');
    _listed.clear();
    final output = <SyncFile>[];
    for (final file in files) {
      if (file is! String) throw const FormatException('Invalid caption filename.');
      _name(file);
      if (!file.startsWith('plezyng-state-v1-$namespace-') || !_listed.add(file)) throw const FormatException('Caption namespace mismatch.');
      output.add(SyncFile(file, file));
    }
    return output;
  }
  void _file(SyncFile file) {
    _name(file.name);
    if (file.id != file.name || !_listed.contains(file.name)) throw StateError('List the current caption revision before reading it.');
  }
  @override
  Future<String> read(SyncFile file) async {
    _file(file);
    final response = await _request('GET', 'objects/${file.name}', bound: maximumBytes + 65536);
    final text = response['text'];
    if (text is! String || utf8.encode(text).length > maximumBytes) throw const FormatException('Invalid caption envelope.');
    return text;
  }
  @override
  Future<void> create(String name, String text) async {
    _name(name);
    if (utf8.encode(text).length > maximumBytes) throw const FormatException('Caption envelope exceeds 2 MiB.');
    await _request('PUT', 'objects', body: {'name': name, 'text': text});
  }
  @override
  Future<void> delete(SyncFile file) async {
    _file(file); await _request('DELETE', 'objects/${file.name}');
  }
}
