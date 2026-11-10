import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../media/media_item.dart';
import '../../media/media_server_client.dart';
import '../../utils/app_logger.dart';
import 'music_guest_dj.dart';
import 'music_library_store.dart';
import 'music_listening_recorder.dart';
import 'music_playback_service.dart';
import 'music_rating_journal.dart';
import 'music_account_scope.dart';
import 'music_history_reconciliation.dart';

/// Created eagerly with the profile session, independent of music screens.
class MusicExperience extends ChangeNotifier {
  MusicExperience({
    required this.music,
    required this.store,
    required this.clientFor,
    Future<List<MusicDjSource>> Function()? sharedSources,
    Stream<Object?>? connectionChanges,
    Iterable<MediaServerClient> Function()? syncClients,
    this.onDispose,
  }) {
    dj = MusicGuestDj(music, clientFor, sharedSources: sharedSources)..addListener(notifyListeners);
    recorder = MusicListeningRecorder(
      music,
      store,
      accountFor: (track) {
        final client = clientFor(track);
        return client == null ? null : musicHistoryAccountScope(client);
      },
    );
    ratings = MusicRatingJournal(store, clientFor);
    history = MusicHistoryReconciliation(store: store, clients: syncClients ?? () => []);
    _connections = connectionChanges?.listen((_) => _syncRatings());
    _syncRatings();
  }
  final MusicPlaybackService music;
  final MusicLibraryStore store;
  final MediaServerClient? Function(MediaItem) clientFor;
  late final MusicGuestDj dj;
  late final MusicListeningRecorder recorder;
  late final MusicRatingJournal ratings;
  late final MusicHistoryReconciliation history;
  final void Function(MusicExperience)? onDispose;
  StreamSubscription<Object?>? _connections;
  void _syncRatings() {
    unawaited(
      ratings.sync().catchError((Object error, StackTrace stack) {
        appLogger.w('Pending music ratings could not be synchronized', error: error, stackTrace: stack);
      }),
    );
  }

  @override
  void dispose() {
    onDispose?.call(this);
    dj.removeListener(notifyListeners);
    dj.dispose();
    recorder.dispose();
    ratings.dispose();
    unawaited(_connections?.cancel());
    super.dispose();
  }
}
