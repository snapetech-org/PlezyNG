import '../../media/media_backend.dart';
import '../../media/media_playlist.dart';
import '../../models/plex/plex_playlist_access.dart';
import '../plex_auth_service.dart';
import '../plex_client.dart';
import 'music_account_scope.dart';

class PlexReceivedPlaylist {
  PlexReceivedPlaylist._(this.playlist, this.access, this._current, this._owner);
  final MediaPlaylist playlist;
  final PlexPlaylistAccessGrant access;
  final bool Function() _current;
  final Object _owner;
  bool get current => _current();
}

class PlexReceivedPlaylistPage {
  const PlexReceivedPlaylistPage({
    required this.items,
    required this.nextOffset,
    required this.hasMore,
    required this.failed,
  });
  final List<PlexReceivedPlaylist> items;
  final int nextOffset, failed;
  final bool hasMore;
}

/// Page accepted playlist grants through an already authorized server client.
/// A shared-item URI is never treated as a network URL or a source of tokens.
class PlexReceivedPlaylists {
  PlexReceivedPlaylists({required this.client, required this.auth, required this.isCurrent})
    : _authentication = client.authenticationSessionId,
      _account = musicAccountScope(client),
      _token = client.plexAccountToken;
  final PlexClient client;
  final PlexAuthService auth;
  final bool Function() isCurrent;
  final Object _authentication;
  final String _account;
  final String? _token;
  List<PlexPlaylistAccessGrant>? _grants;
  int _generation = 0;
  bool get current =>
      isCurrent() &&
      !client.isOfflineMode &&
      _token?.isNotEmpty == true &&
      _token == client.plexAccountToken &&
      identical(_authentication, client.authenticationSessionId) &&
      _account == musicAccountScope(client);

  void _check() {
    if (!current) throw StateError('Received playlist account changed');
  }

  void _pageCurrent(List<PlexPlaylistAccessGrant> grants) {
    _check();
    if (!identical(grants, _grants)) throw StateError('Received playlist page expired');
  }

  Future<void> refresh() async {
    _check();
    final generation = ++_generation;
    _grants = null;
    final root = Uri.parse(await client.buildMetadataUri(''));
    _check();
    if (root.scheme != 'server' ||
        root.host.isEmpty ||
        root.userInfo.isNotEmpty ||
        root.hasPort ||
        root.hasQuery ||
        root.hasFragment ||
        root.path != '/com.plexapp.plugins.library/library/metadata/') {
      throw StateError('Received playlist server is unavailable');
    }
    final grants = await auth.getPlaylistAccess(authToken: _token!, received: true, isCurrent: () => current);
    _check();
    if (generation != _generation) throw StateError('Received playlist refresh expired');
    final seen = <String>{};
    _grants = List.unmodifiable(grants.where((grant) => Uri.parse(grant.uri).host == root.host && seen.add(grant.uri)));
  }

  bool _owns(MediaPlaylist? playlist, String id) =>
      playlist != null &&
      playlist.id == id &&
      playlist.backend == MediaBackend.plex &&
      playlist.serverId == client.serverId.value &&
      playlist.playlistType == 'audio';

  Future<PlexReceivedPlaylistPage> page({int offset = 0, int size = 25}) async {
    _check();
    final grants = _grants;
    if (grants == null) throw StateError('Received playlists have not loaded');
    if (offset < 0 || offset > grants.length || size < 1 || size > 50) {
      throw ArgumentError('Invalid received playlist page');
    }
    final end = (offset + size).clamp(0, grants.length);
    final items = <PlexReceivedPlaylist>[];
    var failed = 0;
    for (var start = offset; start < end; start += 4) {
      _pageCurrent(grants);
      final batch = grants.sublist(start, (start + 4).clamp(0, end));
      final rows = await Future.wait(
        batch.map((grant) async {
          final id = Uri.parse(grant.uri).pathSegments[2];
          try {
            final playlist = await client.fetchPlaylistMetadata(id).timeout(const Duration(seconds: 10));
            _pageCurrent(grants);
            if (!_owns(playlist, id)) {
              failed++;
              return null;
            }
            return PlexReceivedPlaylist._(playlist!, grant, () => current && identical(grants, _grants), this);
          } catch (_) {
            _pageCurrent(grants);
            failed++;
            return null;
          }
        }),
      );
      _pageCurrent(grants);
      items.addAll(rows.whereType<PlexReceivedPlaylist>());
    }
    return PlexReceivedPlaylistPage(
      items: List.unmodifiable(items),
      nextOffset: end,
      hasMore: end < grants.length,
      failed: failed,
    );
  }

  /// Revalidate accepted access after the browse decision and before opening.
  Future<MediaPlaylist> open(PlexReceivedPlaylist entry) async {
    _check();
    if (!entry.current || !identical(entry._owner, this)) throw StateError('Received playlist entry expired');
    final grants = await auth.getPlaylistAccess(
      authToken: _token!,
      received: true,
      playlistUri: entry.access.uri,
      isCurrent: () => current && entry.current,
    );
    if (!grants.any(
      (grant) =>
          grant.itemId == entry.access.itemId &&
          grant.sourceId == entry.access.sourceId &&
          grant.userId == entry.access.userId,
    )) {
      throw StateError('Received playlist access was revoked');
    }
    final playlist = await client.fetchPlaylistMetadata(entry.playlist.id);
    _check();
    if (!entry.current || !_owns(playlist, entry.playlist.id)) throw StateError('Received playlist changed');
    return playlist!;
  }
}
