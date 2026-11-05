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
  bool _starting = false, _ending = false;
  int _revision = 0;
  Timer? _timer;
  bool get live => !_disposed && current();
  Map<String, Object?> get _params => {if (container.isNotEmpty) 'container': container, if (claim.isNotEmpty) 'claimed_at': claim};
  String get _path => 'streaming/sessions/${Uri.encodeComponent(platform)}';
  Future<void> start(RommGame game, {int? stateId, int? saveId, int? memoryCardId, bool multiplayer = false, String? cardImport}) async {
    if (!live) throw const RommFailure('romm.cancelled');
    if (active || _starting || _ending) throw const RommFailure('romm.busy');
    _starting = true;
    try {
    final result = rommMap(await api.json('POST', 'streaming/sessions', body: {'rom_id': game.id,
      if (stateId != null) 'state_id': stateId, if (saveId != null) 'save_id': saveId,
      if (memoryCardId != null) 'memory_card_id': memoryCardId, 'multiplayer': multiplayer, if (cardImport != null) 'card_import': cardImport},
      timeout: const Duration(minutes: 2)));
    platform = rommString(result['platform'], 128); container = rommString(result['container'], 512);
    claim = rommString(result['claimed_at'], 64);
    if (platform.isEmpty || container.isEmpty || claim.isEmpty || DateTime.tryParse(claim) == null) throw const RommFailure('romm.invalidResponse');
    _revision++; owned = true; active = true; room = null; error = '';
    if (!live) { await _release(); return; }
    await poll();
    if (live && active) _timer = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(poll()));
    } finally { _starting = false; }
  }
  Future<void> join(String selectedPlatform, String selectedContainer) async {
    if (!live) throw const RommFailure('romm.cancelled');
    if (active || _starting || _ending) throw const RommFailure('romm.busy');
    if (selectedPlatform.isEmpty || selectedContainer.isEmpty) throw const RommFailure('romm.invalidResponse');
    _starting = true;
    try {
    platform = selectedPlatform; container = selectedContainer;
    final result = rommMap(await api.json('POST', '$_path/join', query: {'container': container}, body: {}));
    if (!live) return;
    room = _room(result['host']); _revision++; active = true; owned = false; error = ''; notifyListeners();
    } finally { _starting = false; }
  }
  Uri _room(Object? value) {
    final raw = rommString(value, 8192), parsed = Uri.tryParse(raw);
    final uri = parsed == null ? null : api.base.resolveUri(parsed);
    if (raw.isEmpty || uri == null || !{'https', 'http'}.contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment) {
      throw const RommFailure('romm.invalidResponse');
    }
    return uri;
  }
  Future<void> poll() async {
    if (!live || !active || !owned || _polling || _ending) return;
    _polling = true;
    final revision = _revision;
    bool currentPoll() => live && active && owned && !_ending && revision == _revision;
    try {
      final status = await api.getMap('$_path/status', query: {'claimed_at': claim});
      if (!currentPoll()) return;
      if (status['status'] != 'active') { _ended(); }
      else {
        phase = rommString(status['extraction_phase'], 100);
        if (rommString(status['host']).isNotEmpty) room = _room(status['host']);
        final heartbeat = rommMap(await api.json('POST', '$_path/heartbeat', query: _params));
        if (!currentPoll()) return;
        if (heartbeat['status'] != 'active') _ended(); else error = '';
      }
    } catch (failure) { if (currentPoll()) error = failure is RommFailure ? failure.code : 'romm.connectionFailed'; }
    finally { _polling = false; if (live) notifyListeners(); }
  }
  void _ended() {
    _revision++; active = false; owned = false; room = null;
    error = 'romm.streamEnded'; _timer?.cancel();
  }
  Future<void> command(String action, Map<String, Object?> body) async {
    if (!live || !owned || !active || _ending || !{'save-state', 'load-state', 'swap-disc', 'volume', 'mute'}.contains(action)) {
      throw const RommFailure('romm.streamEnded');
    }
    await api.json('POST', '$_path/$action', query: _params, body: body, timeout: const Duration(minutes: 2));
  }
  Future<void> finish({bool save = true}) async {
    if (_starting && !save) { dispose(); return; } // A late successful claim releases itself.
    if (_starting || _ending) throw const RommFailure('romm.busy');
    if (!active || !owned) { active = false; return; }
    _ending = true; _revision++;
    try {
    if (save) {
      final result = rommMap(await api.json('POST', '$_path/save-and-exit', query: _params, body: {'slot': 0, 'wait': true},
        timeout: const Duration(minutes: 2)));
      // A dispatched save is not a completed save. Keep the player on failure.
      // If RomM released the claim despite a failed save, never keep beating it
      // or pretend it can be saved again. The caller still sees the failure.
      if (result['released'] == true) { active = false; owned = false; room = null; _timer?.cancel(); }
      if (result['saved'] != true || result['released'] != true) throw const RommFailure('romm.saveFailed');
    } else {
      final result = rommMap(await api.json('DELETE', _path, query: {..._params, 'save': false}));
      if (!{'released', 'not_found'}.contains(result['status'])) throw const RommFailure('romm.invalidResponse');
    }
    active = false; owned = false; room = null; _timer?.cancel();
    } finally { _ending = false; if (live) notifyListeners(); }
  }
  Future<void> _release() async {
    if (!owned || !active) return;
    _revision++; owned = false; active = false; room = null; _timer?.cancel();
    // Retirement uses a dedicated short-lived client: the profile client may
    // already be closed. The immutable claim prevents releasing a replacement.
    final cleanup = RommClient(api.base, token: api.token);
    try { await cleanup.json('DELETE', _path, query: _params); } catch (_) { /* Server heartbeat expiry remains the final recovery path. */ }
    finally { cleanup.close(); }
  }
  @override void dispose() {
    if (_disposed) return;
    _disposed = true; _timer?.cancel(); unawaited(_release()); super.dispose();
  }
}
