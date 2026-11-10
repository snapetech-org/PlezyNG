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
    final entry = {
      'version': 2,
      'id': '$kind:${sha256.convert(utf8.encode(scope))}:${item.globalKey}',
      'revision': const Uuid().v4(),
      'scope': scope,
      'kind': kind,
      'value': value,
      'item': musicIdentity(item).toJson(),
    };
    await store.saveDocument('ratingPending', entry['id'] as String, entry);
    return _send(entry);
  });

  Future<bool> _send(Map<String, dynamic> entry) async {
    // Legacy server-only records cannot be assigned to a Plex account safely.
    if (_disposed || !store.active || entry['version'] != 2) return false;
    final item = MediaItem.fromJson(Map<String, dynamic>.from(entry['item'] as Map));
    final client = clientFor(item);
    if (client == null || client.isOfflineMode || musicAccountScope(client) != entry['scope']) return false;
    final auth = client.authenticationSessionId;
    try {
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
      final current = await store.document('ratingPending', entry['id'] as String);
      if (current?['revision'] == entry['revision']) await store.deleteDocument('ratingPending', entry['id'] as String);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> sync() => _operations.run(() async {
    for (final entry in await store.documents('ratingPending', limit: 500)) {
      if (_disposed) return;
      try {
        await _send(entry);
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
  });
  void dispose() {
    _disposed = true;
  }
}
