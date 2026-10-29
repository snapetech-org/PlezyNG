import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../../services/credential_vault.dart';
import '../../sources/source_database.dart';
import 'romm_capabilities.dart';
import 'romm_client.dart';
import 'romm_models.dart';
import 'romm_storage.dart';

class RommController extends ChangeNotifier {
  RommController({required this.repository, required this.profileId, required this.sessionCurrent});
  late final storage = RommStorage(profileId: profileId, current: () => current, client: client, connection: connection);
  final SourceRepository repository;
  final String profileId;
  final bool Function() sessionCurrent;
  static const preferenceKey = 'games.romm.v1';
  final connections = <RommConnection>[];
  final games = <RommGame>[];
  final favorites = <String>{};
  final recent = <String>[];
  final capabilities = <String, RommCapabilities>{};
  final collections = <String, List<RommCollection>>{};
  final errors = <String, String>{};
  final achievementProgress = <String, Map<String, dynamic>>{};
  final _clients = <String, RommClient>{};
  final _sessionTokens = <String, String>{};
  final _next = <String, int?>{};
  final _covers = <String, Future<Uint8List?>>{};
  final _players = <Object, String>{};
  final _disconnecting = <String>{};
  Future<void> _writes = Future.value();
  bool _disposed = false, busy = false;
  int _queryGeneration = 0;
  String query = '', source = '';
  int? platformId;
  RommCollection? collection;
  bool get current => !_disposed && sessionCurrent();
  bool get hasMore => _next.entries.any((e) => (source.isEmpty || e.key == source) && e.value != null);
  bool hasConnection(String id) => !_disconnecting.contains(id) && connections.any((connection) => connection.id == id);
  void retainPlayer(Object owner, String source) { requireCurrent(); connection(source); _players[owner] = source; }
  void releasePlayer(Object owner) { _players.remove(owner); }
  bool sessionOnly(String id) => _sessionTokens.containsKey(id);
  void requireCurrent() { if (!current) throw const RommFailure('romm.cancelled'); }
  void changed() { if (current) notifyListeners(); }

  Future<void> load() async {
    final data = await repository.preference(profileId, preferenceKey);
    requireCurrent();
    for (final row in rommList(data['connections']).take(12)) {
      try { connections.add(RommConnection.fromJson(rommMap(row))); } catch (_) { /* Malformed persisted connection is not usable. */ }
    }
    final ids = connections.map((s) => s.id).toSet();
    for (final row in rommList(data['games']).take(600)) {
      final map = rommMap(row), id = rommString(rommMap(row)['connectionId'], 128);
      if (ids.contains(id)) games.add(RommGame.fromJson(id, map));
    }
    favorites.addAll(rommList(data['favorites']).take(1000).map((v) => rommString(v, 256)).where((v) => v.isNotEmpty));
    recent.addAll(rommStrings(data['recent']).take(50));
    final cached = rommMap(data['capabilities']);
    for (final id in ids) capabilities[id] = RommCapabilities.cached(rommMap(cached[id]));
    await storage.load();
    requireCurrent();
    final cachedKeys = games.map((g) => g.key).toSet();
    for (final row in storage.downloads.values) {
      final id = rommString(row['connectionId'], 128);
      if (!ids.contains(id)) continue;
      final game = RommGame.fromJson(id, rommMap(row['game']));
      if (cachedKeys.add(game.key)) games.add(game);
    }
    storage.addListener(changed);
    changed();
  }

  Future<void> persist() {
    final pending = _writes.catchError((_) {}).then((_) async {
      requireCurrent();
      await repository.savePreference(profileId, preferenceKey, {
        'connections': connections.map((s) => s.toJson()).toList(),
        'games': games.take(600).map((g) => {...g.toJson(), 'connectionId': g.connectionId}).toList(),
        'favorites': favorites.take(1000).toList(), 'recent': recent.take(50).toList(),
        'capabilities': capabilities.map((id, cap) => MapEntry(id, cap.toJson())),
      });
    });
    _writes = pending;
    return pending;
  }

  RommConnection connection(String id) => connections.firstWhere((c) => c.id == id && !_disconnecting.contains(id),
      orElse: () => throw const RommFailure('romm.notConnected'));
  Future<RommClient> client(String id) async {
    requireCurrent();
    if (!hasConnection(id)) throw const RommFailure('romm.notConnected');
    final cached = _clients[id];
    if (cached != null && !cached.closed) return cached;
    final source = connection(id);
    final token = _sessionTokens[id] ?? (CredentialVault.isProtected(source.credential)
      ? await CredentialVault.reveal(source.credential) : null);
    requireCurrent();
    if (token == null || token.isEmpty) throw const RommFailure('romm.signInAgain');
    if (!connections.contains(source) || !hasConnection(id)) throw const RommFailure('romm.cancelled');
    final existing = _clients[id];
    if (existing != null && !existing.closed) return existing;
    return _clients[id] = RommClient(source.base, token: token);
  }

  Future<void> connect({required String name, required Uri base, required String token,
      String deviceId = '', List<String> scopes = const [], String? replaceId, bool Function()? allowed}) async {
    void checkAttempt() { requireCurrent(); if (allowed?.call() == false) throw const RommFailure('romm.cancelled'); }
    checkAttempt();
    if (token.isEmpty || token.length > 4096 || RegExp(r'[\s\x00-\x1f]').hasMatch(token)) {
      throw const RommFailure('romm.invalidToken');
    }
    final probe = RommClient(base, token: token);
    try {
      final me = await probe.me(), beat = await probe.heartbeat();
      checkAttempt();
      final uid = rommInt(me['id']);
      if (uid == 0) throw const RommFailure('romm.signInAgain');
      if (replaceId != null) {
        final old = connection(replaceId);
        if (old.userId != uid || old.base != base) throw const RommFailure('romm.accountMismatch');
      } else if (connections.length >= 12) { throw const RommFailure('romm.connectionLimit'); }
      final id = replaceId ?? const Uuid().v4();
      String credential = '';
      try { credential = await CredentialVault.protect(token); }
      catch (_) { /* Unsupported vault: keep this session's token only. */ }
      checkAttempt();
      _sessionTokens.remove(id);
      _covers.removeWhere((key, _) => key.startsWith('romm:$id:'));
      if (!CredentialVault.isProtected(credential)) { credential = ''; _sessionTokens[id] = token; }
      final next = RommConnection(id: id, name: name.trim().isEmpty ? base.host : rommString(name.trim(), 128),
        baseUrl: base.toString(), userId: uid, username: rommString(me['username'], 128),
        deviceId: deviceId.isEmpty ? rommString(me['current_device_id'], 128) : deviceId, credential: credential, scopes: scopes,
        version: rommString(rommMap(beat['SYSTEM'])['VERSION'], 64));
      connections.removeWhere((c) => c.id == id); connections.add(next);
      _clients.remove(id)?.close();
      _clients[id] = RommClient(base, token: token);
      errors.remove(id);
      await persist();
      await refresh();
    } finally { probe.close(); }
  }

  Future<void> disconnect(String id) async {
    requireCurrent();
    if (_players.containsValue(id)) throw const RommFailure('romm.saveExitHelp');
    storage.requireNoPendingWork(id);
    if (!_disconnecting.add(id)) return;
    _queryGeneration++; busy = false; changed();
    try {
    await storage.forgetConnectionDownloads(id);
    requireCurrent();
    _queryGeneration++; busy = false;
    _clients.remove(id)?.close(); _sessionTokens.remove(id);
    connections.removeWhere((c) => c.id == id); games.removeWhere((g) => g.connectionId == id);
    capabilities.remove(id); achievementProgress.remove(id); collections.remove(id); errors.remove(id); _next.remove(id);
    favorites.removeWhere((k) => k.startsWith('romm:$id:')); recent.removeWhere((k) => k.startsWith('romm:$id:'));
    _covers.removeWhere((k, _) => k.startsWith('romm:$id:'));
    if (source == id) { source = ''; platformId = null; collection = null; }
    await persist(); changed();
    } finally { _disconnecting.remove(id); changed(); }
  }

  Future<void> refreshCapabilities(String id) async {
    final api = await client(id), me = await (await client(id)).me();
    requireCurrent();
    if (rommInt(me['id']) != connection(id).userId) throw const RommFailure('romm.accountMismatch');
    achievementProgress[id] = rommMap(me['ra_progression']);
    final beat = await api.heartbeat(), config = await api.config();
    Map<String, dynamic> stream = {};
    try { stream = await api.streaming(); } on RommFailure catch (error) { if (error.status != 404 && error.status != 403) rethrow; }
    final platforms = await api.platforms();
    final lists = await api.collections();
    requireCurrent();
    connection(id);
    capabilities[id] = RommCapabilities(version: rommString(rommMap(beat['SYSTEM'])['VERSION'], 64),
      emulation: rommMap(beat['EMULATION']), config: config,
      streams: stream['enabled'] == true ? rommList(stream['containers']).take(500).map(rommMap).toList() : [],
      platforms: platforms, observedAt: DateTime.now());
    collections[id] = lists;
    if (source == id && collection != null && !lists.any((list) => list.kind == collection!.kind && list.id == collection!.id)) collection = null;
    final ownFavorites = lists.where((list) => list.favorite && list.userId == connection(id).userId);
    favorites.removeWhere((key) => key.startsWith('romm:$id:'));
    for (final list in ownFavorites) { favorites.addAll(list.romIds.map((romId) => 'romm:$id:$romId')); }
  }

  Future<void> refresh({String? search, String? connectionId, int? platform, RommCollection? list,
      bool changeFilter = false, bool more = false}) async {
    requireCurrent();
    if (search != null) query = search;
    if (changeFilter) { source = connectionId ?? ''; platformId = platform; collection = list; }
    final epoch = ++_queryGeneration;
    busy = true; changed();
    final selected = connections.where((s) => source.isEmpty || s.id == source).toList();
    try {
      for (final source in selected) {
        if (!current || epoch != _queryGeneration) return;
        if (more && _next[source.id] == null) continue;
        try {
          if (!more && (capabilities[source.id]?.fresh != true || !collections.containsKey(source.id) ||
              search == null && !changeFilter)) await refreshCapabilities(source.id);
          final page = await (await client(source.id)).games(source.id, search: query,
            offset: more ? _next[source.id] ?? 0 : 0, platformId: platformId, collection: collection);
          if (!current || epoch != _queryGeneration) return;
          if (!more) games.removeWhere((g) => g.connectionId == source.id);
          final keys = games.map((g) => g.key).toSet();
          games.addAll(page.games.where((g) => !keys.contains(g.key)));
          _next[source.id] = page.nextOffset; errors.remove(source.id);
        } catch (error) {
          if (!current || epoch != _queryGeneration) return;
          errors[source.id] = error is RommFailure ? error.code : 'romm.connectionFailed';
        }
        changed();
      }
      if (current && epoch == _queryGeneration) {
        await persist();
        unawaited(storage.syncAll().catchError((_) {}));
      }
    } finally { if (current && epoch == _queryGeneration) { busy = false; changed(); } }
  }

  Future<RommGame> detail(RommGame game) async {
    final next = await (await client(game.connectionId)).game(game.connectionId, game.id);
    requireCurrent();
    final index = games.indexWhere((g) => g.key == game.key);
    if (index >= 0) games[index] = next;
    return next;
  }
  Future<void> favorite(RommGame game) async {
    requireCurrent();
    final api = await client(game.connectionId), source = connection(game.connectionId);
    var list = collections[source.id]?.where((list) => list.favorite && list.userId == source.userId).firstOrNull;
    if (list == null) { list = await api.createFavorites(); collections.putIfAbsent(source.id, () => []).add(list); }
    final add = !favorites.contains(game.key);
    await api.collectionMembership(list, game.id, add); requireCurrent();
    if (add) favorites.add(game.key); else favorites.remove(game.key);
    await persist(); changed();
  }
  Future<void> played(RommGame game) async {
    requireCurrent();
    recent.remove(game.key); recent.insert(0, game.key);
    if (recent.length > 50) recent.removeRange(50, recent.length);
    await persist(); changed();
  }
  Future<Uint8List?> cover(RommGame game) {
    if (!current || game.cover.isEmpty) return Future.value();
    final key = '${game.key}:${game.cover}';
    while (_covers.length > 80) _covers.remove(_covers.keys.first);
    return _covers.putIfAbsent(key, () async {
      try {
        final bytes = await (await client(game.connectionId)).asset(game.cover, maximum: 2 * 1024 * 1024);
        return current ? bytes : null;
      } catch (_) { return null; }
    });
  }
  @override void dispose() {
    if (_disposed) return;
    _disposed = true; _queryGeneration++;
    notifyListeners(); // Retire nested player routes before destroying owned clients.
    storage.removeListener(changed); storage.dispose();
    for (final api in _clients.values) api.close();
    _clients.clear(); _sessionTokens.clear(); _covers.clear(); _players.clear();
    super.dispose();
  }
}
