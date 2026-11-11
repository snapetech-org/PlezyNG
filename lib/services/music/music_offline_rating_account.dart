import '../../connection/connection.dart';
import '../../connection/connection_registry.dart';
import '../../media/ids.dart';
import '../../media/media_backend.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/server_capabilities.dart';
import '../../profiles/profile_connection_registry.dart';
import '../../utils/active_client_scope.dart';
import 'music_account_scope.dart';
import 'music_library_store.dart';

typedef MusicRatingAccount = ({String scope, ServerCapabilities capabilities});

/// Resolves local write ownership before server discovery has produced clients.
/// Saved membership is authority to record an intent, never to send a request.
/// The journal still requires a matching live client before replaying it.
class MusicOfflineRatingAccounts {
  MusicOfflineRatingAccounts({
    required this.store,
    required this.connections,
    required this.profiles,
    required this.current,
  });
  final MusicLibraryStore store;
  final ConnectionRegistry connections;
  final ProfileConnectionRegistry profiles;
  final bool Function() current;

  Future<MusicRatingAccount?> forItem(MediaItem item) => store.database.runIdentityMutation(() async {
    if (!store.active ||
        !current() ||
        item.serverId == null ||
        !const [MediaKind.track, MediaKind.album, MediaKind.artist].contains(item.kind)) {
      return null;
    }
    final candidates = <MusicRatingAccount>[];
    for (final binding in await profiles.listForProfile(store.profileId)) {
      final connection = await connections.get(binding.connectionId);
      if (connection is PlexAccountConnection &&
          item.backend == MediaBackend.plex &&
          binding.hasToken &&
          binding.userIdentifier.isNotEmpty &&
          binding.userIdentifier != connection.clientIdentifier &&
          connection.servers.any((server) => server.clientIdentifier == item.serverId)) {
        candidates.add((
          scope: plexMusicAccountScope(
            server: buildPlexProfileScopeId(serverId: ServerId(item.serverId!), profileId: store.profileId),
            account: connection.id,
            user: binding.userIdentifier,
          ),
          capabilities: ServerCapabilities.plex,
        ));
      } else if (connection is PlexDirectConnection &&
          item.backend == MediaBackend.plex &&
          connection.serverMachineId == item.serverId &&
          connection.accessToken.isNotEmpty) {
        candidates.add((
          scope: plexMusicAccountScope(
            server: buildPlexProfileScopeId(serverId: ServerId(item.serverId!), profileId: store.profileId),
            account: connection.id,
            token: connection.accessToken,
          ),
          capabilities: ServerCapabilities.plex,
        ));
      } else if (connection is JellyfinConnection &&
          connection.kind == item.backend &&
          connection.serverMachineId == item.serverId &&
          connection.userId == binding.userIdentifier &&
          connection.accessToken.isNotEmpty) {
        candidates.add((
          scope: '${connection.serverMachineId}/${connection.userId}',
          capabilities: ServerCapabilities.jellyfin,
        ));
      }
    }
    // Several accounts can share a server. Until discovery selects a binding,
    // ambiguity must not silently choose a different music user's rating.
    if (!store.active || !current() || candidates.length != 1) return null;
    return candidates.single;
  });
}
