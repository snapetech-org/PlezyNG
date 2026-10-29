import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

bool validCloudAccount(Object? value) => value is String && RegExp(r'^7656119[0-9]{10}$').hasMatch(value);

/// Account setting state observed by the explicitly installed host extension.
/// Unknown outcomes are never interpreted as false or automatically retried.
class SteamCloudSetting {
  const SteamCloudSetting(this.status, {this.steamId, this.enabled});
  final String status;
  final String? steamId;
  final bool? enabled;
  static SteamCloudSetting parse(Map<String, dynamic> data, String account) {
    if (data['status'] == 'observed' && data['steamId'] == account && data['enabled'] is bool) {
      return SteamCloudSetting('observed', steamId: account, enabled: data['enabled'] as bool);
    }
    return SteamCloudSetting(
      {'denied', 'stale', 'unknown', 'unavailable'}.contains(data['status']) ? data['status'] as String : 'unknown',
    );
  }

  Map<String, dynamic> toJson() => {'status': status, 'steamId': ?steamId, 'enabled': ?enabled};
}

Future<SteamCloudSetting> localSteamCloudSetting(Map<String, dynamic> request, bool Function() current) async {
  if (!Platform.isLinux || !current()) return const SteamCloudSetting('unavailable');
  final runtime = Platform.environment['XDG_RUNTIME_DIR'];
  if (runtime == null || !runtime.startsWith('/') || runtime.length > 100) {
    return const SteamCloudSetting('unavailable');
  }
  Socket? socket;
  Timer? retirement;
  try {
    socket = await Socket.connect(
      InternetAddress('$runtime/plezyng-steam-cloud.sock', type: InternetAddressType.unix),
      0,
      timeout: const Duration(seconds: 2),
    );
    if (!current()) return const SteamCloudSetting('unavailable');
    final connection = socket;
    retirement = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!current()) connection.destroy();
    });
    socket.write('${jsonEncode(request)}\n');
    final response = <int>[];
    final result = await socket
        .timeout(const Duration(seconds: 9))
        .map((chunk) {
          response.addAll(chunk);
          if (response.length > 2048) throw const FormatException('Oversized Cloud bridge response');
          return chunk;
        })
        .fold<List<int>>(response, (value, _) => value);
    if (!current()) return const SteamCloudSetting('unknown');
    return SteamCloudSetting.parse(
      Map<String, dynamic>.from(jsonDecode(utf8.decode(result)) as Map),
      request['steamId'] as String,
    );
  } catch (_) {
    return SteamCloudSetting(request['op'] == 'set' ? 'unknown' : 'unavailable');
  } finally {
    retirement?.cancel();
    socket?.destroy();
  }
}

/// Append-only Companion extension. The host permission and connection/profile
/// generation are rechecked through the asynchronous local transaction.
class SteamCloudSettingsExchange {
  SteamCloudSettingsExchange({required this.isHost, required this.allowed, required this.execute, required this.send});
  final bool isHost;
  final bool Function() allowed;
  final Future<SteamCloudSetting> Function(Map<String, dynamic>, bool Function()) execute;
  final void Function(Map<String, dynamic>) send;
  final Set<String> _seen = {};
  bool _closed = false, _serving = false;
  int _generation = 0;
  Completer<SteamCloudSetting>? _pending;
  String? _id, _account;
  Timer? _timer;

  Future<SteamCloudSetting> request(String steamId, {bool? expected, bool? enabled}) {
    if (!validCloudAccount(steamId) ||
        (enabled == null) != (expected == null) ||
        isHost ||
        _closed ||
        _pending != null) {
      return Future.value(const SteamCloudSetting('unavailable'));
    }
    final random = Random.secure();
    _id = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    _account = steamId;
    final pending = _pending = Completer<SteamCloudSetting>();
    _timer = Timer(const Duration(seconds: 12), () => _finish(const SteamCloudSetting('unknown')));
    send({
      'version': 1,
      'request': _id,
      'op': enabled == null ? 'read' : 'set',
      'steamId': steamId,
      'expected': ?expected,
      'enabled': ?enabled,
    });
    return pending.future;
  }

  void receive(Map<String, dynamic>? data) {
    if (_closed || data == null || data['version'] != 1) return;
    final id = data['request'];
    if (id is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) return;
    if (isHost) {
      unawaited(_serve(id, data));
      return;
    }
    if (id == _id && _account != null && data['op'] == 'result') _finish(SteamCloudSetting.parse(data, _account!));
  }

  Future<void> _serve(String id, Map<String, dynamic> data) async {
    if (_seen.contains(id)) return;
    if (_seen.length >= 256) {
      _reply(id, const SteamCloudSetting('denied'));
      return;
    }
    _seen.add(id);
    final write = data['op'] == 'set';
    if (data.keys.any((key) => !{'version', 'request', 'op', 'steamId', 'expected', 'enabled'}.contains(key)) ||
        !validCloudAccount(data['steamId']) ||
        (write
            ? data['expected'] is! bool || data['enabled'] is! bool
            : data['op'] != 'read' || data.containsKey('expected') || data.containsKey('enabled'))) {
      _reply(id, const SteamCloudSetting('denied'));
      return;
    }
    if (!allowed()) {
      _reply(id, const SteamCloudSetting('denied'));
      return;
    }
    if (_serving) {
      _reply(id, const SteamCloudSetting('unavailable'));
      return;
    }
    _serving = true;
    final generation = _generation;
    var active = true;
    bool current() => active && !_closed && generation == _generation && allowed();
    try {
      final request = Map<String, dynamic>.of(data)..remove('request');
      final result = await execute(request, current).timeout(const Duration(seconds: 10));
      if (current()) _reply(id, SteamCloudSetting.parse(result.toJson(), data['steamId'] as String));
    } catch (_) {
      if (current()) _reply(id, const SteamCloudSetting('unknown'));
    } finally {
      active = false;
      if (generation == _generation) _serving = false;
    }
  }

  void _reply(String id, SteamCloudSetting result) =>
      send({'version': 1, 'request': id, 'op': 'result', ...result.toJson()});
  void _finish(SteamCloudSetting result) {
    final pending = _pending;
    _pending = null;
    _id = null;
    _account = null;
    _timer?.cancel();
    _timer = null;
    pending?.complete(result);
  }

  void reset() {
    _generation++;
    _serving = false;
    _seen.clear();
    _finish(const SteamCloudSetting('unknown'));
  }

  void close() {
    _closed = true;
    reset();
  }
}
