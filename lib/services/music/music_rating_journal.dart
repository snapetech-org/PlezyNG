import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../../media/media_item.dart';
import '../../media/media_server_client.dart';
import '../../utils/serial_future_queue.dart';
import 'music_account_scope.dart';
import 'music_library_store.dart';

/// Last explicit rating/favorite decision wins locally. Remote writes are
/// idempotent setters, serialized per profile and bound to their user scope.
/// A successful old acknowledgement never deletes a more recent queued edit.
class MusicRatingJournal {
  MusicRatingJournal(this.store, this.clientFor);
  final MusicLibraryStore store;
  final MediaServerClient? Function(MediaItem) clientFor;
  final SerialFutureQueue _operations = SerialFutureQueue();
  bool _disposed = false;

  Future<bool> rate(MediaItem item, double value) => _queue(item, 'rating', value);
  Future<bool> favorite(MediaItem item, bool value) => _queue(item, 'favorite', value);
  Future<bool> _queue(MediaItem item, String kind, Object value) => _operations.run(() async {
    if (_disposed || !store.active) throw StateError('Music profile is no longer active');
    final client = clientFor(item);
    if (client == null) throw StateError('Music account unavailable');
    if (kind == 'rating' &&
        (!client.capabilities.numericUserRating ||
            value is! double ||
            !value.isFinite ||
            value != -1 && (value < 0 || value > 10))) {
      throw ArgumentError('Unsupported numeric rating');
    }
    if (kind == 'favorite' && !client.capabilities.userFavorites) throw UnsupportedError('No favorite flag');
    final scope = musicAccountScope(client);
    final id = '$kind:${sha256.convert(utf8.encode(scope))}:${item.globalKey}';
    final previous = await store.document('ratingPending', id);
    if (_disposed || !store.active || !identical(clientFor(item), client) || musicAccountScope(client) != scope) {
      throw StateError('Music account changed');
    }
    final entry = {
      'version': 3,
      'id': id,
      'revision': const Uuid().v4(),
      'scope': scope,
      'kind': kind,
      'value': value,
      'item': musicIdentity(item).toJson(),
      'base': previous != null && previous['version'] == 3
          ? previous['base']
          : (kind == 'rating' ? item.userRating : item.isFavorite),
    };
    await store.saveDocument('ratingPending', entry['id'] as String, entry);
    await store.deleteDocument('ratingConflict', id);
    return _send(entry);
  });

  Future<bool> _send(Map<String, dynamic> entry, {bool verifyRemote = false}) async {
    // Legacy server-only records cannot be assigned to a Plex account safely.
    if (_disposed || !store.active || !const [2, 3].contains(entry['version'])) return false;
    final item = MediaItem.fromJson(Map<String, dynamic>.from(entry['item'] as Map));
    final client = clientFor(item);
    if (client == null || client.isOfflineMode || musicAccountScope(client) != entry['scope']) return false;
    final auth = client.authenticationSessionId;
    try {
      bool current() =>
          !_disposed &&
          store.active &&
          identical(auth, client.authenticationSessionId) &&
          identical(clientFor(item), client) &&
          musicAccountScope(client) == entry['scope'];
      if (verifyRemote) {
        final conflict = await store.document('ratingConflict', entry['id'] as String);
        if (!current() || conflict?['revision'] == entry['revision']) return false;
        final remote = await client.fetchItem(item.id);
        if (!current() ||
            remote == null ||
            remote.globalKey != item.globalKey ||
            remote.kind != item.kind ||
            remote.backend != item.backend) {
          return false;
        }
        Object? normalized(Object? value) => entry['kind'] == 'rating' && value == -1 ? null : value;
        final remoteValue = entry['kind'] == 'rating' ? remote.userRating : remote.isFavorite;
        if (normalized(remoteValue) == normalized(entry['value'])) {
          final pending = await store.document('ratingPending', entry['id'] as String);
          if (!current() || pending?['revision'] != entry['revision']) return false;
          await store.deleteDocument('ratingPending', entry['id'] as String);
          return true;
        }
        if (entry['version'] != 3 || normalized(remoteValue) != normalized(entry['base'])) {
          await store.saveDocument('ratingConflict', entry['id'] as String, {...entry, 'remote': remoteValue});
          return false;
        }
      }
      if (entry['kind'] == 'rating' && client.capabilities.numericUserRating) {
        await client.rate(item, (entry['value'] as num).toDouble());
      } else if (entry['kind'] == 'favorite' && client.capabilities.userFavorites) {
        await client.setFavorite(item, entry['value'] as bool);
      } else {
        return false;
      }
      if (_disposed ||
          !identical(auth, client.authenticationSessionId) ||
          !identical(clientFor(item), client) ||
          musicAccountScope(client) != entry['scope']) {
        return false;
      }
      final pending = await store.document('ratingPending', entry['id'] as String);
      if (pending?['revision'] == entry['revision']) await store.deleteDocument('ratingPending', entry['id'] as String);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> sync() => _operations.run(() async {
    (int, String)? cursor;
    do {
      if (_disposed || !store.active) return;
      final page = await store.documentPage('ratingPending', after: cursor);
      for (final entry in page.entries) {
        if (_disposed) return;
        try {
          await _send(entry, verifyRemote: true);
        } on FormatException {
          continue;
        } on TypeError {
          continue;
        }
      }
      cursor = page.cursor;
    } while (cursor != null);
  });

  Future<bool> resolveConflict(String id, String revision, {required bool keepLocal}) => _operations.run(() async {
    if (_disposed || !store.active) return false;
    final conflict = await store.document('ratingConflict', id);
    final pending = await store.document('ratingPending', id);
    if (conflict == null || pending == null || conflict['revision'] != revision || pending['revision'] != revision) {
      return false;
    }
    final item = MediaItem.fromJson(Map<String, dynamic>.from(pending['item'] as Map));
    final client = clientFor(item);
    if (client == null || client.isOfflineMode || musicAccountScope(client) != pending['scope']) return false;
    if (!keepLocal) {
      await store.deleteDocument('ratingPending', id);
      await store.deleteDocument('ratingConflict', id);
      return true;
    }
    final updated = {...pending, 'version': 3, 'base': conflict['remote']};
    await store.saveDocument('ratingPending', id, updated);
    await store.deleteDocument('ratingConflict', id);
    return _send(updated, verifyRemote: true);
  });
  void dispose() {
    _disposed = true;
  }
}
