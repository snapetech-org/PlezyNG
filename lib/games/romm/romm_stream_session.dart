import 'dart:async';
import 'package:flutter/foundation.dart';
import 'romm_client.dart';
import 'romm_models.dart';

class RommStreamSession extends ChangeNotifier {
  RommStreamSession(this.api, this.current);
  final RommClient api;
  final bool Function() current;
  String platform = '', container = '', claim = '', phase = '', error = '';
  Uri? room;
  bool active = false, owned = false, _disposed = false, _polling = false;
  Timer? _timer;
  bool get live => !_disposed && current();
  Map<String, Object?> get _params => {if (container.isNotEmpty) 'container': container, if (claim.isNotEmpty) 'claimed_at': claim};
  String get _path => 'streaming/sessions/${Uri.encodeComponent(platform)}';
  Future<void> start(RommGame game, {int? stateId, int? saveId, int? memoryCardId, bool multiplayer = false, String? cardImport}) async {
    if (!live || active) return;
    final result = rommMap(await api.json('POST', 'streaming/sessions', body: {'rom_id': game.id,
      if (stateId != null) 'state_id': stateId, if (saveId != null) 'save_id': saveId,
      if (memoryCardId != null) 'memory_card_id': memoryCardId, 'multiplayer': multiplayer, if (cardImport != null) 'card_import': cardImport}));
    platform = rommString(result['platform'], 128); container = rommString(result['container'], 512);
    claim = rommString(result['claimed_at'], 80);
    if (platform.isEmpty || container.isEmpty || claim.isEmpty) throw const RommFailure('romm.invalidResponse');
    owned = true; active = true;
    if (!live) { await _release(); return; }
    await poll();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(poll()));
  }
  Future<void> join(String selectedPlatform, String selectedContainer) async {
    if (!live || active) return;
    platform = selectedPlatform; container = selectedContainer;
    final result = rommMap(await api.json('POST', '$_path/join', query: {'container': container}, body: {}));
    if (!live) return;
    room = _room(result['host']); active = true; owned = false; notifyListeners();
  }
  Uri _room(Object? value) {
    final raw = rommString(value, 8192), parsed = Uri.tryParse(raw);
    final uri = parsed == null ? null : api.base.resolveUri(parsed);
    if (uri == null || !{'https', 'http'}.contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment) {
      throw const RommFailure('romm.invalidResponse');
    }
    return uri;
  }
  Future<void> poll() async {
    if (!live || !active || !owned || _polling) return;
    _polling = true;
    try {
      final status = await api.getMap('$_path/status', query: {'claimed_at': claim});
      if (!live) return;
      if (status['status'] != 'active') { active = false; error = 'romm.streamEnded'; _timer?.cancel(); }
      else {
        phase = rommString(status['extraction_phase'], 100);
        if (rommString(status['host']).isNotEmpty) room = _room(status['host']);
        await api.json('POST', '$_path/heartbeat', query: _params);
        error = '';
      }
    } catch (failure) { if (live) error = failure is RommFailure ? failure.code : 'romm.connectionFailed'; }
    finally { _polling = false; if (live) notifyListeners(); }
  }
  Future<void> command(String action, Map<String, Object?> body) async {
    if (!live || !owned || !active || !{'save-state', 'load-state', 'swap-disc', 'volume', 'mute'}.contains(action)) {
      throw const RommFailure('romm.streamEnded');
    }
    await api.json('POST', '$_path/$action', query: _params, body: body);
  }
  Future<void> finish({bool save = true}) async {
    if (!active || !owned) { active = false; return; }
    if (save) {
      final result = rommMap(await api.json('POST', '$_path/save-and-exit', query: _params, body: {'slot': 0, 'wait': true}));
      // A dispatched save is not a completed save. Keep the player on failure.
      if (result['saved'] != true || result['released'] != true) throw const RommFailure('romm.saveFailed');
    } else {
      await api.json('DELETE', _path, query: {..._params, 'save': false});
    }
    active = false; owned = false; _timer?.cancel();
  }
  Future<void> _release() async {
    if (!owned || !active) return;
    owned = false; active = false;
    // Retirement uses a dedicated short-lived client: the profile client may
    // already be closed. The immutable claim prevents releasing a replacement.
    final cleanup = RommClient(api.base, token: api.token);
    try { await cleanup.json('DELETE', _path, query: _params); } catch (_) { /* Server heartbeat expiry remains the final recovery path. */ }
    finally { cleanup.close(); }
  }
  @override void dispose() {
    _disposed = true; _timer?.cancel(); unawaited(_release()); super.dispose();
  }
}
