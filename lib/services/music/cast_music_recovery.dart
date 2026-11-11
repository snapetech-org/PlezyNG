import '../../utils/serial_future_queue.dart';
import '../multi_server_manager.dart';
import 'cast_music_output.dart';
import 'cast_music_queue.dart';
import 'music_library_store.dart';

/// One profile's acknowledged detached queue. Documents contain catalog and
/// account fingerprints only; resolved Cast stream URLs are deliberately absent.
class CastMusicRecovery {
  CastMusicRecovery(this.store, this.manager);
  final MusicLibraryStore store;
  final MultiServerManager manager;
  final _operations = SerialFutureQueue();
  Map<String, dynamic>? _cached;
  bool _loaded = false;

  Future<Map<String, dynamic>?> read() => _operations.run(() async {
    if (!store.active) return null;
    if (!_loaded) {
      _cached = await store.document('castQueue', 'detached');
      _loaded = true;
    }
    return store.active ? _cached : null;
  });

  Future<void> save(CastMusicQueue queue, CastReceiverKey connection) => _operations.run(() async {
    final document = queue.recoveryDocument(connection);
    await store.saveDocument('castQueue', 'detached', document);
    _cached = document;
    _loaded = true;
  });

  Future<void> clear({String? token}) => _operations.run(() async {
    if (!store.active) return;
    final document = await store.document('castQueue', 'detached');
    if (token != null && document?['token'] != token) return;
    await store.deleteDocument('castQueue', 'detached');
    _cached = null;
    _loaded = true;
  });
}
