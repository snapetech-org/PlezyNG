import 'dart:convert';

import '../../media/media_item.dart';
import '../../media/media_server_client.dart';
import 'music_account_scope.dart';
import 'music_library_store.dart';

final musicHistoryAccountPattern = RegExp(r'^[a-f0-9]{64}$');
final _occurrencePattern = RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$');
const _identityFields = {
  'backend',
  'id',
  'kind',
  'serverId',
  'libraryId',
  'title',
  'parentId',
  'parentTitle',
  'grandparentId',
  'grandparentTitle',
  'durationMs',
  'year',
  'index',
  'parentIndex',
};

Map<String, dynamic> musicHistoryToWire(MusicHistoryEntry entry) {
  final identity = musicIdentity(entry.item).toJson();
  final item = <String, dynamic>{
    for (final key in _identityFields)
      if (identity[key] != null)
        key: identity[key] is String
            ? (identity[key] as String).substring(0, (identity[key] as String).length.clamp(0, 512))
            : identity[key],
  };
  return {
    'id': entry.id,
    'account': entry.account,
    'item': item,
    'started': entry.startedAt.toUtc().millisecondsSinceEpoch,
    'listened': entry.listenedMs,
    'finished': entry.finished,
  };
}

MusicHistoryEntry musicHistoryFromWire(Object? value, {DateTime? now}) {
  if (value is! Map<String, dynamic> ||
      value.keys.toSet().difference({'id', 'account', 'item', 'started', 'listened', 'finished'}).isNotEmpty) {
    throw const FormatException('Invalid listening event');
  }
  final id = value['id'], account = value['account'], item = value['item'];
  final started = value['started'], listened = value['listened'], finished = value['finished'];
  final latest = (now ?? DateTime.now()).add(const Duration(minutes: 5)).millisecondsSinceEpoch;
  if (id is! String ||
      !_occurrencePattern.hasMatch(id) ||
      account is! String ||
      !musicHistoryAccountPattern.hasMatch(account) ||
      started is! int ||
      started < 0 ||
      started > latest ||
      listened is! int ||
      listened < 0 ||
      listened > const Duration(days: 30).inMilliseconds ||
      finished is! bool ||
      item is! Map<String, dynamic> ||
      item.keys.any((key) => !_identityFields.contains(key)) ||
      item['kind'] != 'track') {
    throw const FormatException('Invalid listening event identity');
  }
  for (final key in ['id', 'serverId', 'backend']) {
    if (item[key] is! String || (item[key] as String).isEmpty) throw const FormatException('Missing media identity');
  }
  for (final entry in item.entries) {
    if ({'durationMs', 'year', 'index', 'parentIndex'}.contains(entry.key)) {
      if (entry.value is! int ||
          (entry.value as int) < 0 ||
          (entry.value as int) > const Duration(days: 7).inMilliseconds) {
        throw const FormatException('Invalid media number');
      }
    } else if (entry.value is! String || (entry.value as String).length > 512) {
      throw const FormatException('Invalid media text');
    }
  }
  final track = MediaItem.fromJson(item);
  if (track.backend.name != item['backend']) throw const FormatException('Unknown media backend');
  return MusicHistoryEntry(
    id: id,
    item: track,
    startedAt: DateTime.fromMillisecondsSinceEpoch(started, isUtc: true),
    listenedMs: listened,
    finished: finished,
    account: account,
  );
}

class MusicHistoryReconciliation {
  MusicHistoryReconciliation({required this.store, required this.clients});
  final MusicLibraryStore store;
  final Iterable<MediaServerClient> Function() clients;

  Map<String, MediaServerClient> _accounts() => {
    for (final client in clients())
      if (!client.isOfflineMode && musicHistoryAccountScope(client) != null) musicHistoryAccountScope(client)!: client,
  };

  Set<String> get accounts => store.active ? _accounts().keys.take(32).toSet() : {};

  Future<MusicHistoryPage> exportPage(Set<String> requested, (int, String)? before, bool Function() current) async {
    if (!store.active || !current()) throw StateError('History profile changed');
    final accounts = _accounts();
    final selected = requested.intersection(accounts.keys.toSet());
    final authentication = {
      for (final account in selected) accounts[account]!: accounts[account]!.authenticationSessionId,
    };
    final page = await store.historySyncPage(accounts: selected, before: before);
    if (!store.active || !current() || !_authority(authentication)) throw StateError('History account changed');
    return MusicHistoryPage([
      for (final entry in page.entries)
        if (entry.account != null &&
            accounts[entry.account]?.serverId.value == entry.item.serverId &&
            accounts[entry.account]?.backend == entry.item.backend &&
            _occurrencePattern.hasMatch(entry.id))
          entry,
    ], page.cursor);
  }

  bool _authority(Map<MediaServerClient, Object> authentication) {
    final visible = clients().toSet();
    return authentication.entries.every(
      (entry) =>
          visible.contains(entry.key) &&
          !entry.key.isOfflineMode &&
          identical(entry.key.authenticationSessionId, entry.value),
    );
  }

  Future<bool> merge(List<MusicHistoryEntry> entries, bool Function() current) async {
    if (entries.length > 8 || !store.active || !current()) return false;
    final accounts = _accounts();
    final authentication = <MediaServerClient, Object>{};
    for (final entry in entries) {
      final client = accounts[entry.account];
      if (client == null || client.backend != entry.item.backend || client.serverId.value != entry.item.serverId) {
        return false;
      }
      authentication[client] = client.authenticationSessionId;
    }
    bool valid() =>
        store.active &&
        current() &&
        _authority(authentication) &&
        entries.every((entry) => musicHistoryAccountScope(accounts[entry.account]!) == entry.account);
    try {
      await store.database.transaction(() async {
        if (!valid()) throw StateError('History authority changed');
        for (final entry in entries) {
          await store.record(
            id: entry.id,
            track: entry.item,
            startedAt: entry.startedAt,
            listenedMs: entry.listenedMs,
            finished: entry.finished,
            account: entry.account,
            current: valid,
          );
          if (!valid()) throw StateError('History authority changed');
        }
      });
      return valid();
    } on StateError {
      return false;
    }
  }
}

int compareHistoryCursor((int, String) first, (int, String) second) {
  final timestamp = first.$1.compareTo(second.$1);
  return timestamp == 0 ? first.$2.compareTo(second.$2) : timestamp;
}

(int, String)? historyCursorFromWire(Object? value) {
  if (value == null) return null;
  if (value is! List ||
      value.length != 2 ||
      value[0] is! int ||
      value[0] < 0 ||
      value[1] is! String ||
      (value[1] as String).isEmpty ||
      (value[1] as String).length > 128) {
    throw const FormatException('Invalid history cursor');
  }
  return (value[0] as int, value[1] as String);
}

bool boundedMusicHistoryMessage(Map<String, dynamic> value) => utf8.encode(jsonEncode(value)).length <= 48 * 1024;
