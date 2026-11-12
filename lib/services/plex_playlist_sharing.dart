import '../media/media_backend.dart';
import '../media/media_playlist.dart';
import '../models/plex/plex_playlist_access.dart';
import 'music/music_account_scope.dart';
import 'plex_auth_service.dart';
import 'plex_client.dart';

/// Public, credential-free decision shown to the person granting access.
class PlexPlaylistAccessDraft {
  const PlexPlaylistAccessDraft._(this.playlist, this.uri);
  final MediaPlaylist playlist;
  final String uri;
}

/// Pins one server/account and the caller's verified owner/profile lease.
/// Shared-source acknowledgements are not proof an invite was accepted.
class PlexPlaylistSharing {
  PlexPlaylistSharing({required this.client, required this.auth, required this.playlist, required this.isCurrent})
    : _authentication = client.authenticationSessionId,
      _account = musicAccountScope(client),
      _token = client.plexAccountToken;
  final PlexClient client;
  final PlexAuthService auth;
  final MediaPlaylist playlist;
  final bool Function() isCurrent;
  final Object _authentication;
  final String _account;
  final String? _token;
  PlexPlaylistAccessDraft? _prepared;
  bool _busy = false, _accepted = false;

  bool get current =>
      isCurrent() &&
      !client.isOfflineMode &&
      _token != null &&
      _token.isNotEmpty &&
      _token == client.plexAccountToken &&
      identical(_authentication, client.authenticationSessionId) &&
      _account == musicAccountScope(client);

  void _check() {
    if (!current) throw StateError('Playlist sharing source changed');
  }

  bool _owns(MediaPlaylist? fresh) =>
      fresh != null &&
      fresh.id == playlist.id &&
      fresh.backend == MediaBackend.plex &&
      fresh.serverId == client.serverId.value &&
      fresh.serverId == playlist.serverId &&
      fresh.playlistType == 'audio' &&
      playlist.playlistType == 'audio' &&
      fresh.smart == playlist.smart;

  Future<PlexPlaylistAccessDraft> prepare() async {
    _check();
    if (playlist.backend != MediaBackend.plex || !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(playlist.id)) {
      throw ArgumentError('A Plex playlist is required');
    }
    final fresh = await client.fetchPlaylistMetadata(playlist.id);
    _check();
    if (!_owns(fresh)) throw StateError('Playlist is no longer available');
    final root = Uri.parse(await client.buildMetadataUri(''));
    _check();
    if (root.scheme != 'server' ||
        root.host.isEmpty ||
        root.userInfo.isNotEmpty ||
        root.hasPort ||
        root.hasQuery ||
        root.hasFragment ||
        root.path != '/com.plexapp.plugins.library/library/metadata/') {
      throw StateError('Playlist server is unavailable');
    }
    final uri = root.replace(path: '/com.plexapp.plugins.library/playlists/${playlist.id}/items').toString();
    _grants = const [];
    return _prepared = PlexPlaylistAccessDraft._(fresh!, uri);
  }

  List<PlexPlaylistAccessGrant> _grants = const [];

  void _decision(PlexPlaylistAccessDraft draft) {
    _check();
    if (!identical(draft, _prepared) || _busy || _accepted) {
      throw StateError('Playlist sharing decision expired');
    }
  }

  Future<void> _validatePlaylist(PlexPlaylistAccessDraft draft) async {
    final fresh = await client.fetchPlaylistMetadata(playlist.id);
    _check();
    if (!_owns(fresh) || fresh!.title != draft.playlist.title) {
      throw StateError('Playlist changed during sharing');
    }
  }

  Future<List<PlexPlaylistAccessGrant>> listAccess(PlexPlaylistAccessDraft draft) async {
    _decision(draft);
    final grants = await auth.getPlaylistAccess(authToken: _token!, playlistUri: draft.uri, isCurrent: () => current);
    _decision(draft);
    return _grants = grants;
  }

  Future<void> revoke(PlexPlaylistAccessDraft draft, PlexPlaylistAccessGrant grant) async {
    _decision(draft);
    if (!_grants.contains(grant) || grant.received || grant.uri != draft.uri) {
      throw StateError('Playlist access decision expired');
    }
    _busy = true;
    try {
      await _validatePlaylist(draft);
      await auth.revokePlaylistAccess(authToken: _token!, grant: grant, isCurrent: () => current);
      _check();
      _grants = List.unmodifiable(_grants.where((item) => !identical(item, grant)));
    } finally {
      _busy = false;
    }
  }

  Future<int> grant(PlexPlaylistAccessDraft draft, String recipient) async {
    _decision(draft);
    _busy = true;
    try {
      // Validate the resource again after the recipient/name decision. An
      // update to the contents is allowed: this grants a live playlist.
      await _validatePlaylist(draft);
      final source = await auth.grantPlaylistAccess(
        authToken: _token!,
        playlistUri: draft.uri,
        title: draft.playlist.title,
        recipient: recipient,
        isCurrent: () => current,
      );
      _check();
      _accepted = true;
      return source;
    } finally {
      _busy = false;
    }
  }
}
